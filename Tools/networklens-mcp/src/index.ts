#!/usr/bin/env node
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { readFile, writeFile } from "node:fs/promises";
import { z } from "zod";
import { resolveTracePath } from "./container.js";
import {
  MockRule,
  RELAUNCH_NOTE,
  blockedByRunningApp,
  Session,
  findRule,
  findScenario,
  findVariant,
  readSession,
  resolveSessionPath,
  toSnapshotDate,
  sameRule,
  writeSession,
} from "./session.js";
import { redacted } from "./redact.js";
import { LIVE_NOTE, LiveEdit, controlEndpoint, liveEdit, liveRefusal, liveState } from "./control.js";
import { emptied, failed, newID, ruleFor, standardSet, variant } from "./variants.js";
import {
  Entry,
  Exchange,
  Trace,
  decodeBody,
  durationMs,
  preview,
  resolvePointer,
  searchBody,
  statusOf,
} from "./trace.js";

/** Hard ceiling on any single body payload returned to the model. A tool that
 *  can dump a megabyte into context is a tool that makes answers worse. */
const MAX_BODY_CHARS = 8_000;

let trace: Trace | null = null;
let traceHow = "";

async function currentTrace(): Promise<Trace> {
  if (trace) return trace;
  const resolved = await resolveTracePath();
  traceHow = resolved.how;
  trace = new Trace(resolved.path);
  return trace;
}

function text(value: string) {
  return { content: [{ type: "text" as const, text: value }] };
}

/**
 * The running app first, the session file second.
 *
 * A finished result means the app answered — applied, or refused because it
 * disagreed. `null` means nobody was listening, which is the ordinary case with
 * no sidecar running, and the caller writes the file exactly as it always did.
 */
async function live(edit: LiveEdit, summary: string[]): Promise<ReturnType<typeof text> | null> {
  const result = await liveEdit(edit);
  if (result.ok) return text([...summary, "", LIVE_NOTE].join("\n"));
  if (result.reachable) return text(liveRefusal(result));
  return null;
}

function parsedBody(snapshot?: { body?: string | null } | null): unknown {
  const raw = decodeBody(snapshot?.body);
  if (!raw) return null;
  try {
    return JSON.parse(raw.toString("utf8"));
  } catch {
    return raw.toString("utf8");
  }
}

function summarise(entry: Entry): string {
  const exchange = entry.exchange;
  const ms = durationMs(exchange);
  const bytes = exchange.response?.originalBodyByteCount ?? decodeBody(exchange.response?.body)?.length ?? 0;
  const flags = [
    exchange.isMockServed ? "MOCKED" : null,
    exchange.replayOf ? "REPLAY" : null,
    exchange.response?.bodyTruncated ? "TRUNCATED" : null,
    entry.revisions > 1 ? `EDITED×${entry.revisions - 1}` : null,
  ].filter(Boolean);

  return [
    exchange.id.slice(0, 8),
    statusOf(exchange).padStart(3),
    ms === null ? "   —" : `${String(ms).padStart(4)}ms`,
    `${String(bytes).padStart(7)}B`,
    exchange.screen ?? "-",
    exchange.endpointKey,
    flags.length ? `[${flags.join(" ")}]` : "",
  ].join("  ").trimEnd();
}

function find(entries: Entry[], id: string): Entry | undefined {
  return entries.find((entry) => entry.exchange.id === id || entry.exchange.id.startsWith(id));
}

function clip(value: string): string {
  return value.length > MAX_BODY_CHARS
    ? `${value.slice(0, MAX_BODY_CHARS)}\n\n… truncated at ${MAX_BODY_CHARS} chars. Narrow it with a pointer.`
    : value;
}


// MARK: - Rules

/**
 * Read fresh on every call rather than cached like the trace.
 *
 * The app autosaves this file on each edit made in the overlay, so a cached
 * copy would silently undo whatever the tester did between two tool calls.
 */
async function currentSession(): Promise<{ session: Session; path: string; how: string }> {
  const resolved = await resolveSessionPath();
  return { session: await readSession(resolved.path), path: resolved.path, how: resolved.how };
}

function describeRule(rule: MockRule): string {
  const active = rule.variants.find((variant) => variant.id === rule.activeVariantID);
  const names = rule.variants
    .map((variant) => (variant.id === rule.activeVariantID ? `*${variant.name}*` : variant.name))
    .join(", ");
  return `${rule.isEnabled ? "on " : "off"}  ${rule.endpointKey}  →  ${active?.name ?? "—"}   [${names}]`;
}

const server = new McpServer({ name: "networklens", version: "0.1.0" });

server.tool(
  "lens_status",
  "Where the trace is and what it holds. Start here when nothing else returns rows.",
  {},
  async () => {
    const active = await currentTrace();
    try {
      const entries = await active.entries();
      const sessions = [...new Set(entries.map((entry) => entry.sessionID))];
      const latest = sessions[sessions.length - 1];
      return text(
        [
          `path:     ${active.path}`,
          `resolved: ${traceHow}`,
          `exchanges: ${entries.length}  sessions: ${sessions.length}`,
          `latest session: ${latest ?? "—"} (${entries.filter((e) => e.sessionID === latest).length} exchanges)`,
        ].join("\n")
      );
    } catch (error) {
      return text(`path:     ${active.path}\nresolved: ${traceHow}\n\n${(error as Error).message}`);
    }
  }
);

server.tool(
  "lens_list",
  "One line per exchange: id, status, duration, size, screen, endpoint, flags. Never returns bodies.",
  {
    screen: z.string().optional().describe("Exact screen name, e.g. Checkout"),
    endpoint: z.string().optional().describe("Substring match on the endpoint key"),
    status: z.string().optional().describe("Exact status (500) or class (5xx, 4xx)"),
    failedOnly: z.boolean().optional(),
    session: z.string().optional().describe("Session id; defaults to the most recent"),
    allSessions: z.boolean().optional(),
    limit: z.number().int().min(1).max(200).optional(),
  },
  async (args) => {
    const entries = await (await currentTrace()).entries();
    if (!entries.length) return text("No exchanges in the trace yet.");

    const sessions = [...new Set(entries.map((entry) => entry.sessionID))];
    const target = args.session ?? sessions[sessions.length - 1];

    let rows = args.allSessions ? entries : entries.filter((entry) => entry.sessionID === target);

    if (args.screen) rows = rows.filter((entry) => entry.exchange.screen === args.screen);
    if (args.endpoint) {
      const needle = args.endpoint.toLowerCase();
      rows = rows.filter((entry) => entry.exchange.endpointKey.toLowerCase().includes(needle));
    }
    if (args.status) {
      const wanted = args.status.toLowerCase();
      rows = rows.filter((entry) => {
        const code = statusOf(entry.exchange);
        return wanted.endsWith("xx") ? code.startsWith(wanted[0]) : code === wanted;
      });
    }
    if (args.failedOnly) {
      rows = rows.filter((entry) => {
        const code = Number(statusOf(entry.exchange));
        return Number.isNaN(code) || code >= 400;
      });
    }

    const limit = args.limit ?? 50;
    const shown = rows.slice(-limit);
    const header = `${shown.length} of ${rows.length} matching (session ${args.allSessions ? "all" : target?.slice(0, 8)})`;
    const dropped = rows.length > shown.length ? `\n… ${rows.length - shown.length} older rows not shown.` : "";

    return text(`${header}\n\n${shown.map(summarise).join("\n")}${dropped}`);
  }
);

server.tool(
  "lens_get",
  "Metadata for one exchange — headers, timing, flags. Bodies come from lens_body.",
  {
    id: z.string().describe("Full or short exchange id from lens_list"),
    part: z.enum(["all", "headers", "timing", "meta"]).optional(),
  },
  async (args) => {
    const entry = find(await (await currentTrace()).entries(), args.id);
    if (!entry) return text(`No exchange matching ${args.id}.`);

    const exchange = entry.exchange;
    const part = args.part ?? "all";
    const sections: string[] = [];

    if (part === "all" || part === "meta") {
      sections.push(
        [
          `id:          ${exchange.id}`,
          `endpoint:    ${exchange.endpointKey}`,
          `screen:      ${exchange.screen ?? "—"}`,
          `method/url:  ${exchange.request.method} ${exchange.request.url}`,
          `status:      ${statusOf(exchange)}`,
          `started:     ${exchange.startedAt}`,
          `mock served: ${exchange.isMockServed ? "yes" : "no"}`,
          `replay of:   ${exchange.replayOf ?? "—"}`,
          `revisions:   ${entry.revisions}`,
          bodyNote(exchange),
        ]
          .filter(Boolean)
          .join("\n")
      );
    }
    if (part === "all" || part === "headers") {
      sections.push(
        `request headers:\n${format(exchange.request.headers)}\n\nresponse headers:\n${format(exchange.response?.headers)}`
      );
    }
    if (part === "all" || part === "timing") {
      sections.push(`timing:\n${exchange.timing ? format(exchange.timing as Record<string, unknown>) : "  —"}`);
    }

    return text(sections.join("\n\n"));
  }
);

function bodyNote(exchange: Exchange): string {
  const response = exchange.response;
  if (!response) return "";
  const held = decodeBody(response.body)?.length ?? 0;
  const original = response.originalBodyByteCount;
  if (response.bodyTruncated && original) {
    return `body:        ${held}B held of ${original}B — TRUNCATED, reasoning on this body may be incomplete`;
  }
  return `body:        ${held}B`;
}

function format(record?: Record<string, unknown> | null): string {
  if (!record || !Object.keys(record).length) return "  —";
  return Object.entries(record)
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([key, value]) => `  ${key}: ${String(value)}`)
    .join("\n");
}

server.tool(
  "lens_body",
  "A slice of one body, addressed by JSON Pointer. Prefer a pointer over reading the whole payload.",
  {
    id: z.string(),
    side: z.enum(["response", "request"]).optional(),
    pointer: z.string().optional().describe("RFC 6901 pointer, e.g. /data/items/0. Omit for the root."),
    depth: z.number().int().min(1).max(6).optional().describe("Collapse below this depth to type summaries"),
  },
  async (args) => {
    const entry = find(await (await currentTrace()).entries(), args.id);
    if (!entry) return text(`No exchange matching ${args.id}.`);

    const side = args.side ?? "response";
    const snapshot = side === "response" ? entry.exchange.response : entry.exchange.request;
    const body = parsedBody(snapshot);
    if (body === null) return text(`${side} has no body.`);

    const pointer = args.pointer ?? "";
    const value = resolvePointer(body, pointer);
    if (value === undefined) return text(`Pointer ${pointer} does not resolve in this ${side} body.`);

    const shaped = args.depth ? collapseDepth(value, args.depth) : value;
    const rendered = typeof shaped === "string" ? shaped : JSON.stringify(shaped, null, 2);
    const warning = snapshot?.bodyTruncated ? "\n\n(body was truncated at capture time — this is a prefix)" : "";

    return text(`${pointer || "/"}:\n${clip(rendered)}${warning}`);
  }
);

/** Replaces anything below `depth` with a shape summary, so the root of a large
 *  payload is readable without pulling its leaves along. */
function collapseDepth(value: unknown, depth: number): unknown {
  if (depth <= 0) {
    if (Array.isArray(value)) return `[… ${value.length} items]`;
    if (value !== null && typeof value === "object") {
      return `{… ${Object.keys(value as object).length} keys}`;
    }
    return value;
  }
  if (Array.isArray(value)) return value.map((item) => collapseDepth(item, depth - 1));
  if (value !== null && typeof value === "object") {
    return Object.fromEntries(
      Object.entries(value as Record<string, unknown>).map(([key, child]) => [key, collapseDepth(child, depth - 1)])
    );
  }
  return value;
}

server.tool(
  "lens_search",
  "Find a key or value across bodies. Returns pointers to read with lens_body, not the payloads.",
  {
    query: z.string(),
    side: z.enum(["response", "request", "both"]).optional(),
    limit: z.number().int().min(1).max(50).optional(),
  },
  async (args) => {
    const entries = await (await currentTrace()).entries();
    const side = args.side ?? "response";
    const limit = args.limit ?? 20;
    const found: string[] = [];

    for (const entry of entries) {
      const sides = side === "both" ? (["response", "request"] as const) : ([side] as const);
      for (const which of sides) {
        const snapshot = which === "response" ? entry.exchange.response : entry.exchange.request;
        const body = parsedBody(snapshot);
        if (body === null) continue;
        for (const hit of searchBody(body, args.query, "", [], 5)) {
          found.push(
            `${entry.exchange.id.slice(0, 8)}  ${entry.exchange.endpointKey}  ${which}${hit.pointer}  →  ${hit.snippet}`
          );
          if (found.length >= limit) break;
        }
      }
      if (found.length >= limit) break;
    }

    if (!found.length) return text(`No match for "${args.query}".`);
    return text(`${found.length} hit(s):\n\n${found.join("\n")}`);
  }
);

server.tool(
  "lens_stats",
  "Session shape: counts by endpoint, status class, slowest calls, mocked vs live.",
  { session: z.string().optional(), allSessions: z.boolean().optional() },
  async (args) => {
    const entries = await (await currentTrace()).entries();
    if (!entries.length) return text("No exchanges in the trace yet.");

    const sessions = [...new Set(entries.map((entry) => entry.sessionID))];
    const target = args.session ?? sessions[sessions.length - 1];
    const rows = args.allSessions ? entries : entries.filter((entry) => entry.sessionID === target);

    const byEndpoint = new Map<string, number>();
    const byClass = new Map<string, number>();
    let mocked = 0;
    for (const entry of rows) {
      byEndpoint.set(entry.exchange.endpointKey, (byEndpoint.get(entry.exchange.endpointKey) ?? 0) + 1);
      const code = statusOf(entry.exchange);
      const bucket = /^\d/.test(code) ? `${code[0]}xx` : code;
      byClass.set(bucket, (byClass.get(bucket) ?? 0) + 1);
      if (entry.exchange.isMockServed) mocked += 1;
    }

    const slowest = rows
      .map((entry) => ({ entry, ms: durationMs(entry.exchange) }))
      .filter((row): row is { entry: Entry; ms: number } => row.ms !== null)
      .sort((a, b) => b.ms - a.ms)
      .slice(0, 5);

    const rank = (map: Map<string, number>) =>
      [...map.entries()].sort((a, b) => b[1] - a[1]).map(([key, count]) => `  ${String(count).padStart(4)}  ${key}`);

    return text(
      [
        `session ${args.allSessions ? "all" : target?.slice(0, 8)} — ${rows.length} exchanges, ${mocked} mock-served`,
        "",
        "by status:",
        ...rank(byClass),
        "",
        "by endpoint:",
        ...rank(byEndpoint).slice(0, 15),
        "",
        "slowest:",
        ...slowest.map((row) => `  ${String(row.ms).padStart(5)}ms  ${row.entry.exchange.endpointKey}`),
      ].join("\n")
    );
  }
);

server.tool(
  "lens_curl",
  "Rebuild one request as a curl command. Redacted headers stay redacted.",
  { id: z.string() },
  async (args) => {
    const entry = find(await (await currentTrace()).entries(), args.id);
    if (!entry) return text(`No exchange matching ${args.id}.`);

    const request = entry.exchange.request;
    const parts = [`curl -X ${request.method ?? "GET"} '${request.url}'`];
    for (const [key, value] of Object.entries(request.headers ?? {})) {
      parts.push(`  -H '${key}: ${value}'`);
    }
    const body = decodeBody(request.body);
    if (body) parts.push(`  --data-raw '${body.toString("utf8").replace(/'/g, "'\\''")}'`);

    return text(
      `${parts.join(" \\\n")}\n\n(headers were redacted before the trace was written — substitute a real value for any <redacted> before running)`
    );
  }
);

server.tool(
  "lens_diff",
  "What changed between two calls — status, timing, and which body pointers differ.",
  { idA: z.string(), idB: z.string(), limit: z.number().int().min(1).max(100).optional() },
  async (args) => {
    const entries = await (await currentTrace()).entries();
    const a = find(entries, args.idA);
    const b = find(entries, args.idB);
    if (!a || !b) return text(`Could not resolve ${!a ? args.idA : args.idB}.`);

    const lines = [
      `endpoint:  ${a.exchange.endpointKey}  vs  ${b.exchange.endpointKey}`,
      `status:    ${statusOf(a.exchange)}  vs  ${statusOf(b.exchange)}`,
      `duration:  ${durationMs(a.exchange) ?? "—"}ms  vs  ${durationMs(b.exchange) ?? "—"}ms`,
      "",
    ];

    const differences: string[] = [];
    diffValues(parsedBody(a.exchange.response), parsedBody(b.exchange.response), "", differences, args.limit ?? 40);
    lines.push(differences.length ? `body differences:\n${differences.join("\n")}` : "bodies are identical.");

    return text(lines.join("\n"));
  }
);

function diffValues(a: unknown, b: unknown, pointer: string, out: string[], limit: number): void {
  if (out.length >= limit) return;

  const bothObjects =
    a !== null && b !== null && typeof a === "object" && typeof b === "object" && Array.isArray(a) === Array.isArray(b);

  if (!bothObjects) {
    if (JSON.stringify(a) !== JSON.stringify(b)) {
      out.push(`  ${pointer || "/"}: ${preview(a, 60)}  →  ${preview(b, 60)}`);
    }
    return;
  }

  const keys = new Set([
    ...Object.keys(a as Record<string, unknown>),
    ...Object.keys(b as Record<string, unknown>),
  ]);
  for (const key of keys) {
    diffValues(
      (a as Record<string, unknown>)[key],
      (b as Record<string, unknown>)[key],
      `${pointer}/${key}`,
      out,
      limit
    );
    if (out.length >= limit) return;
  }
}


// MARK: - Write tools
//
// Everything below edits the rules file the app reads at launch. None of it
// reaches a running app: the overlay owns that file while the process lives and
// autosaves over it, so a write mid-session is both invisible and lost. Every
// tool here therefore ends on RELAUNCH_NOTE rather than pretending otherwise.

server.tool(
  "lens_mocks",
  "Mock rules on the device: which endpoints are mocked, their variants, and which variant is live. Read-only.",
  {},
  async () => {
    const { session, path, how } = await currentSession();
    if (!session.mocks.length) {
      return text(`No rules in ${path} (${how}).\nSave a mock in the overlay first, or import a pack.`);
    }
    return text(
      [
        `mocking master switch: ${session.isMockingEnabled ? "ON" : "OFF"}`,
        `${session.mocks.length} rules · ${session.scenarios.length} scenarios`,
        "",
        ...session.mocks.map(describeRule),
      ].join("\n")
    );
  }
);

server.tool(
  "lens_scenarios",
  "Saved scenarios on the device, with what each one pins.",
  {},
  async () => {
    const { session } = await currentSession();
    if (!session.scenarios.length) return text("No scenarios saved. Import a pack, or save one in the overlay.");

    return text(
      session.scenarios
        .map((scenario) => {
          const on = scenario.entries.filter((entry) => entry.isEnabled);
          const detail = on.length
            ? on.map((entry) => `${entry.endpointKey} → ${entry.variantName}`).join("\n      ")
            : "all rules off (live traffic)";
          return `${scenario.name}\n      ${detail}`;
        })
        .join("\n\n")
    );
  }
);

server.tool(
  "lens_apply_scenario",
  "Set every rule the way a saved scenario describes. Takes effect on the next launch.",
  {
    name: z.string().describe("Scenario name, or enough of it to be unambiguous"),
    enableMocking: z.boolean().optional().describe("Also turn the master switch on. Default true — a scenario applied with mocking off changes nothing."),
  },
  async (args) => {
    const { session, path } = await currentSession();
    const scenario = findScenario(session, args.name);
    if (!scenario) {
      return text(`No scenario matching “${args.name}”. Known: ${session.scenarios.map((s) => s.name).join(", ") || "none"}`);
    }

    const changes: string[] = [];
    const missing: string[] = [];
    const touched: MockRule[] = [];

    for (const entry of scenario.entries) {
      const rule = session.mocks.find((candidate) => sameRule(candidate, entry));
      if (!rule) {
        missing.push(entry.endpointKey);
        continue;
      }
      // By id first, by name second: a rule rebuilt on another device keeps its
      // variant names but not their ids.
      const variant =
        rule.variants.find((candidate) => candidate.id === entry.variantID) ??
        rule.variants.find((candidate) => candidate.name === entry.variantName);
      if (!variant) {
        missing.push(`${entry.endpointKey} (no variant ${entry.variantName})`);
        continue;
      }
      rule.activeVariantID = variant.id;
      rule.isEnabled = entry.isEnabled;
      touched.push(rule);
      changes.push(`${entry.isEnabled ? "on " : "off"}  ${rule.endpointKey} → ${variant.name}`);
    }

    if (args.enableMocking !== false) session.isMockingEnabled = true;

    const summary = [
      `Applied “${scenario.name}” — ${changes.length} rules set${missing.length ? `, ${missing.length} missing` : ""}.`,
      ...changes.map((line) => `  ${line}`),
      ...(missing.length ? ["", "missing:", ...missing.map((line) => `  ${line}`)] : []),
    ];

    const answered = await live(
      { rules: touched, isMockingEnabled: args.enableMocking !== false ? true : undefined },
      summary
    );
    if (answered) return answered;

    const blocked = await blockedByRunningApp();
    if (blocked) return text(blocked);

    await writeSession(path, session);
    return text([...summary, "", RELAUNCH_NOTE].join("\n"));
  }
);

server.tool(
  "lens_set_variant",
  "Point one endpoint at one variant, or turn its rule off so it serves live traffic again.",
  {
    endpoint: z.string().describe("Endpoint key, or a substring of it"),
    variant: z.string().optional().describe("Variant name, or a substring. Omit when only toggling enabled."),
    enabled: z.boolean().optional().describe("false serves live traffic for this endpoint. Default true."),
  },
  async (args) => {
    const { session, path } = await currentSession();
    const rule = findRule(session, args.endpoint);
    if (!rule) {
      return text(`No rule matching “${args.endpoint}”. Known:\n${session.mocks.map((r) => `  ${r.endpointKey}`).join("\n") || "  none"}`);
    }

    if (args.variant) {
      const variant = findVariant(rule, args.variant);
      if (!variant) {
        return text(`No variant matching “${args.variant}” on ${rule.endpointKey}. Has: ${rule.variants.map((v) => v.name).join(", ")}`);
      }
      rule.activeVariantID = variant.id;
    }
    if (args.enabled !== undefined) rule.isEnabled = args.enabled;

    const summary = [describeRule(rule)];
    const answered = await live({ rules: [rule], isMockingEnabled: rule.isEnabled ? true : undefined }, summary);
    if (answered) return answered;

    const blocked = await blockedByRunningApp();
    if (blocked) return text(blocked);

    await writeSession(path, session);
    return text([...summary, "", RELAUNCH_NOTE].join("\n"));
  }
);

server.tool(
  "lens_set_mocking",
  "The master switch. Off means every rule is ignored, whatever each one says.",
  { enabled: z.boolean() },
  async (args) => {
    const summary = [`Mocking ${args.enabled ? "ON" : "OFF"}.`];
    const answered = await live({ isMockingEnabled: args.enabled }, summary);
    if (answered) return answered;

    const blocked = await blockedByRunningApp();
    if (blocked) return text(blocked);

    const { session, path } = await currentSession();
    session.isMockingEnabled = args.enabled;
    await writeSession(path, session);
    return text([...summary, "", RELAUNCH_NOTE].join("\n"));
  }
);

server.tool(
  "lens_import_pack",
  "Merge a .networklens-pack.json into the device: its scenarios and the rules they need.",
  { file: z.string().describe("Path to the pack file") },
  async (args) => {
    const { session, path } = await currentSession();

    let pack: { name?: string; scenarios?: Session["scenarios"]; mocks?: MockRule[]; formatVersion?: number };
    try {
      pack = JSON.parse(await readFile(args.file, "utf8"));
    } catch (error) {
      return text(`Could not read ${args.file}: ${(error as Error).message}`);
    }
    if ((pack.formatVersion ?? 1) > 1) {
      return text(`Pack format ${pack.formatVersion} is newer than this server understands (1).`);
    }

    let addedRules = 0;
    let replacedRules = 0;
    for (const rule of pack.mocks ?? []) {
      const index = session.mocks.findIndex((candidate) => sameRule(candidate, rule));
      if (index >= 0) {
        session.mocks[index] = rule;
        replacedRules += 1;
      } else {
        session.mocks.push(rule);
        addedRules += 1;
      }
    }

    let addedScenarios = 0;
    let replacedScenarios = 0;
    const converted: Session["scenarios"] = [];
    for (const raw of pack.scenarios ?? []) {
      // The pack's ISO date is not what the session file's decoder expects.
      const scenario = { ...raw, createdAt: toSnapshotDate(raw.createdAt) as unknown as string };
      converted.push(scenario);
      const index = session.scenarios.findIndex(
        (candidate) => candidate.id === scenario.id || candidate.name === scenario.name
      );
      if (index >= 0) {
        session.scenarios[index] = scenario;
        replacedScenarios += 1;
      } else {
        session.scenarios.push(scenario);
        addedScenarios += 1;
      }
    }

    const summary = [
      `Imported “${pack.name ?? args.file}”.`,
      `  rules:     ${addedRules} added, ${replacedRules} replaced`,
      `  scenarios: ${addedScenarios} added, ${replacedScenarios} replaced`,
      "",
      "Apply one with lens_apply_scenario.",
    ];

    const answered = await live({ rules: pack.mocks ?? [], scenarios: converted }, summary);
    if (answered) return answered;

    const blocked = await blockedByRunningApp();
    if (blocked) return text(blocked);

    await writeSession(path, session);
    return text([...summary, RELAUNCH_NOTE].join("\n"));
  }
);


// MARK: - Authoring
//
// The half that was missing. Reading a trace and flipping an existing rule is
// useless if creating the rule still means thirty taps in the overlay — which
// is why one screen had a pack and the rest did not.

/** The latest live (non-mocked) 200 for an endpoint. A mocked hit would make
 *  the new rule a copy of the old mock, which is how a stale variant becomes
 *  permanent. */
function latestLive(entries: Entry[], match: (exchange: Exchange) => boolean): Entry | undefined {
  let found: Entry | undefined;
  for (const entry of entries) {
    if (entry.exchange.isMockServed) continue;
    if ((entry.exchange.response?.statusCode ?? 0) !== 200) continue;
    if (!match(entry.exchange)) continue;
    found = entry;
  }
  return found;
}

function upsertRule(session: Session, rule: MockRule): "added" | "replaced" {
  const index = session.mocks.findIndex((candidate) => sameRule(candidate, rule));
  if (index >= 0) {
    session.mocks[index] = rule;
    return "replaced";
  }
  session.mocks.push(rule);
  return "added";
}

server.tool(
  "lens_live",
  "Whether writes will reach the running app or only the session file. Run this when a mock seems not to have applied.",
  {},
  async () => {
    const result = await liveState();
    if (result.ok) {
      const rules = (result.outcome?.rules ?? []) as MockRule[];
      const on = rules.filter((rule) => rule.isEnabled);
      return text(
        [
          "Live. Writes take effect immediately.",
          `  queue:    ${await controlEndpoint()}`,
          `  mocking:  ${result.outcome?.isMockingEnabled ? "ON" : "OFF"}`,
          `  rules:    ${rules.length} (${on.length} enabled)`,
          ...on.map((rule) => `    ${rule.endpointKey}`),
        ].join("\n")
      );
    }
    if (result.reachable) return text(`The app answered, but refused: ${result.error}`);
    return text(
      [
        `Not live — ${result.error}.`,
        `  queue: ${await controlEndpoint()}`,
        "",
        "Writes will go to the session file and need a relaunch. To go live:",
        "  1. pass control: ControlOptions() in the app's LensConfiguration",
        "  2. launch the app in the simulator",
        "",
        "The queue is hosted by this server, so there is nothing else to start.",
      ].join("\n")
    );
  }
);

server.tool(
  "lens_mock_endpoint",
  "Turn a captured response into a rule carrying loaded / empty / 500 / slow / timeout. The rule arrives disabled.",
  {
    endpoint: z.string().describe("Substring of the endpoint key, e.g. flashsale/v2/products"),
    slowDelay: z.number().optional().describe("Seconds the slow variant waits. Default 3."),
    replace: z.boolean().optional().describe("Overwrite an existing rule for this endpoint. Default false — an edited rule is someone's work."),
  },
  async (args) => {
    const needle = args.endpoint.toLowerCase();
    const entries = await (await currentTrace()).entries();
    const entry = latestLive(entries, (exchange) => exchange.endpointKey.toLowerCase().includes(needle));
    if (!entry) return text(`No live 200 captured for “${args.endpoint}”. Walk the screen with mocking off first.`);

    const { session, path } = await currentSession();
    const existing = session.mocks.find((rule) => rule.endpointKey === entry.exchange.endpointKey);
    if (existing && !args.replace) {
      return text(
        `${entry.exchange.endpointKey} already has a rule (${existing.variants.map((v) => v.name).join(", ")}).\n` +
          "Pass replace: true to rebuild it from the capture — that discards any hand-edited variant."
      );
    }

    const response = entry.exchange.response;
    const rule = ruleFor(
      entry.exchange.endpointKey,
      standardSet(decodeBody(response?.body), response?.statusCode ?? 200, response?.headers ?? {}, args.slowDelay ?? 3)
    );
    const summary = [
      `${existing ? "replaced" : "added"} ${rule.endpointKey}`,
      `  variants: ${rule.variants.map((v) => v.name).join(", ")}`,
      `  from: ${entry.exchange.id.slice(0, 8)} · ${response?.originalBodyByteCount ?? 0}B · ${entry.exchange.screen ?? "no screen"}`,
      "  disabled, so nothing changes until you enable it",
    ];

    const answered = await live({ rules: [rule] }, summary);
    if (answered) return answered;

    const blocked = await blockedByRunningApp();
    if (blocked) return text(blocked);

    upsertRule(session, rule);
    await writeSession(path, session);
    return text([...summary, "", RELAUNCH_NOTE].join("\n"));
  }
);

server.tool(
  "lens_mock_screen",
  "One screen's traffic becomes rules plus the scenarios that switch them together: loaded, empty, 500, slow, live.",
  {
    screen: z.string().describe("Screen name as it appears in lens_list"),
    slowDelay: z.number().optional(),
    replace: z.boolean().optional().describe("Rebuild rules that already exist. Default false — existing rules are left alone and still get scenario entries."),
  },
  async (args) => {
    const entries = await (await currentTrace()).entries();
    const onScreen = entries.filter((entry) => entry.exchange.screen === args.screen);
    if (!onScreen.length) {
      const known = [...new Set(entries.map((entry) => entry.exchange.screen).filter(Boolean))];
      return text(`Nothing captured on “${args.screen}”. Known screens: ${known.join(", ") || "none — the app is not reporting a screen"}`);
    }

    const { session, path } = await currentSession();
    const keys = [...new Set(onScreen.map((entry) => entry.exchange.endpointKey))];
    const built: string[] = [];
    const skipped: string[] = [];

    for (const key of keys) {
      const existing = session.mocks.find((rule) => rule.endpointKey === key);
      if (existing && !args.replace) {
        skipped.push(key);
        continue;
      }
      const entry = latestLive(onScreen, (exchange) => exchange.endpointKey === key);
      if (!entry) {
        skipped.push(`${key} (no live 200)`);
        continue;
      }
      const response = entry.exchange.response;
      upsertRule(
        session,
        ruleFor(
          key,
          standardSet(decodeBody(response?.body), response?.statusCode ?? 200, response?.headers ?? {}, args.slowDelay ?? 3)
        )
      );
      built.push(key);
    }

    // Scenarios cover every endpoint on the screen, the pre-existing rules
    // included: the unit being switched is the screen, and leaving one endpoint
    // on whatever the last scenario set produces a state nobody chose.
    const rules = session.mocks.filter((rule) => keys.includes(rule.endpointKey));
    const madeScenarios: string[] = [];
    const builtScenarios: Session["scenarios"] = [];

    const saveScenario = (name: string, pick: (rule: MockRule) => { id: string; name: string } | null, enabled: boolean) => {
      const entries = rules
        .map((rule) => {
          const chosen = pick(rule);
          if (!chosen) return null;
          return {
            endpointKey: rule.endpointKey,
            match: rule.match,
            variantID: chosen.id,
            variantName: chosen.name,
            isEnabled: enabled,
          };
        })
        .filter((entry): entry is NonNullable<typeof entry> => entry !== null);
      if (!entries.length) return;

      const scenario = {
        id: newID(),
        name,
        group: args.screen,
        createdAt: toSnapshotDate(undefined) as unknown as string,
        entries,
      };
      const index = session.scenarios.findIndex((candidate) => candidate.name === name);
      if (index >= 0) session.scenarios[index] = scenario;
      else session.scenarios.push(scenario);
      builtScenarios.push(scenario);
      madeScenarios.push(name);
    };

    for (const state of ["loaded", "empty", "500", "slow"]) {
      saveScenario(`${args.screen} — ${state}`, (rule) => rule.variants.find((v) => v.name === state) ?? null, true);
    }
    saveScenario(`${args.screen} — live`, (rule) => rule.variants[0] ?? null, false);

    const summary = [
      `${args.screen}: ${built.length} rules built, ${madeScenarios.length} scenarios.`,
      ...built.map((key) => `  + ${key}`),
      ...(skipped.length ? ["", "left alone:", ...skipped.map((key) => `  · ${key}`)] : []),
      "",
      `scenarios: ${madeScenarios.join(", ")}`,
      "Rules are disabled until a scenario is applied.",
    ];

    // Every rule on the screen, not only the new ones: a scenario naming a rule
    // the app has never seen resolves to nothing when it is applied.
    const answered = await live({ rules, scenarios: builtScenarios }, summary);
    if (answered) return answered;

    const blocked = await blockedByRunningApp();
    if (blocked) return text(blocked);

    await writeSession(path, session);
    return text([...summary, RELAUNCH_NOTE].join("\n"));
  }
);

server.tool(
  "lens_set_variant_body",
  "Replace what one variant serves — an edited payload, a status code, a delay. Creates the variant if the rule has no such name.",
  {
    endpoint: z.string().describe("Endpoint key, or a substring"),
    variant: z.string().describe("Variant name to write. A new name adds a variant rather than editing one."),
    file: z.string().optional().describe("Path to a JSON file to serve. Either this or body."),
    body: z.string().optional().describe("Inline body. Either this or file."),
    statusCode: z.number().int().optional().describe("Default 200."),
    delay: z.number().optional().describe("Seconds before responding. Default 0."),
    derive: z.enum(["empty", "500"]).optional().describe("Instead of a body, derive one from the rule's loaded variant."),
    activate: z.boolean().optional().describe("Also make this the live variant and enable the rule. Default false."),
  },
  async (args) => {
    const { session, path } = await currentSession();
    const rule = findRule(session, args.endpoint);
    if (!rule) return text(`No rule matching “${args.endpoint}”. Create one with lens_mock_endpoint.`);

    let payload: Buffer;
    if (args.derive) {
      const loaded = rule.variants.find((candidate) => candidate.name === "loaded") ?? rule.variants[0];
      const step = loaded?.steps?.[0] as { respond?: { _0?: { body?: string } } } | undefined;
      const captured = Buffer.from(step?.respond?._0?.body ?? "", "base64");
      payload = args.derive === "empty" ? emptied(captured) : failed(captured);
    } else if (args.file) {
      try {
        payload = await readFile(args.file);
      } catch (error) {
        return text(`Could not read ${args.file}: ${(error as Error).message}`);
      }
    } else if (args.body !== undefined) {
      payload = Buffer.from(args.body, "utf8");
    } else {
      return text("Nothing to serve — pass file, body, or derive.");
    }

    const status = args.statusCode ?? (args.derive === "500" ? 500 : 200);
    const step = {
      respond: {
        _0: {
          body: payload.toString("base64"),
          delay: args.delay ?? 0,
          headers: { "Content-Type": "application/json" },
          statusCode: status,
        },
      },
    };

    const existing = rule.variants.find((candidate) => candidate.name === args.variant);
    if (existing) existing.steps = [step];
    else rule.variants.push(variant(args.variant, [step]));

    if (args.activate) {
      const target = rule.variants.find((candidate) => candidate.name === args.variant);
      if (target) rule.activeVariantID = target.id;
      rule.isEnabled = true;
      session.isMockingEnabled = true;
    }

    const summary = [
      `${existing ? "rewrote" : "added"} “${args.variant}” on ${rule.endpointKey}`,
      `  ${status} · ${payload.length}B${args.delay ? ` · ${args.delay}s delay` : ""}${args.activate ? " · live" : ""}`,
    ];

    const answered = await live({ rules: [rule], isMockingEnabled: args.activate ? true : undefined }, summary);
    if (answered) return answered;

    const blocked = await blockedByRunningApp();
    if (blocked) return text(blocked);

    await writeSession(path, session);
    return text([...summary, "", RELAUNCH_NOTE].join("\n"));
  }
);

server.tool(
  "lens_delete_rule",
  "Remove rules, and the scenario entries that pointed at them. The way out of a stale mock that is quietly serving an old body.",
  {
    endpoint: z.string().describe("Endpoint key or substring. Every matching rule goes."),
    dryRun: z.boolean().optional().describe("List what would go without writing. Default false."),
  },
  async (args) => {
    const { session, path } = await currentSession();
    const needle = args.endpoint.trim().toLowerCase();
    const doomed = session.mocks.filter((rule) => rule.endpointKey.toLowerCase().includes(needle));
    if (!doomed.length) return text(`No rule matching “${args.endpoint}”.`);

    if (args.dryRun) {
      return text([`Would remove ${doomed.length} rule(s):`, ...doomed.map((rule) => `  ${rule.endpointKey}`)].join("\n"));
    }

    const keys = new Set(doomed.map((rule) => rule.endpointKey));
    session.mocks = session.mocks.filter((rule) => !keys.has(rule.endpointKey));

    // A scenario left pointing at a deleted rule silently applies less than it
    // claims to, which is worse than one that is honestly shorter.
    let prunedEntries = 0;
    const emptiedScenarios: string[] = [];
    for (const scenario of session.scenarios) {
      const before = scenario.entries.length;
      scenario.entries = scenario.entries.filter((entry) => !keys.has(entry.endpointKey));
      prunedEntries += before - scenario.entries.length;
      if (!scenario.entries.length) emptiedScenarios.push(scenario.name);
    }
    session.scenarios = session.scenarios.filter((scenario) => scenario.entries.length > 0);

    const summary = [
      `Removed ${doomed.length} rule(s), ${prunedEntries} scenario entr${prunedEntries === 1 ? "y" : "ies"}.`,
      ...doomed.map((rule) => `  - ${rule.endpointKey}`),
      ...(emptiedScenarios.length ? ["", `dropped now-empty scenarios: ${emptiedScenarios.join(", ")}`] : []),
    ];

    // Exact keys rather than the substring the caller typed: the match already
    // happened here, and re-matching in the app could catch a rule this did not.
    const answered = await live({ removeEndpointKeys: [...keys], scenarios: session.scenarios }, summary);
    if (answered) return answered;

    const blocked = await blockedByRunningApp();
    if (blocked) return text(blocked);

    await writeSession(path, session);
    return text([...summary, "", RELAUNCH_NOTE].join("\n"));
  }
);

/** Seconds between the Unix epoch and Swift's reference date, 2001-01-01. */
const SWIFT_REFERENCE_EPOCH = 978_307_200;

/** The pack format's date, which is ISO-8601 — the session file's is not. */
function packDate(value: unknown): string {
  const seconds = typeof value === "number" ? value + SWIFT_REFERENCE_EPOCH : Date.now() / 1000;
  return new Date(seconds * 1000).toISOString().replace(/(\.\d{3})Z$/, "$1Z");
}

server.tool(
  "lens_export_pack",
  "Write the device's rules and scenarios out as a shareable .networklens-pack.json — the way a tester's setup becomes a committed file.",
  {
    file: z.string().describe("Where to write it"),
    name: z.string().optional().describe("Pack name. Defaults to the file's base name."),
    notes: z.string().optional(),
    group: z.string().optional().describe("Export only scenarios in this group, and the rules they name."),
    redact: z.boolean().optional().describe("Strip credentials and payment fields from every body and header. Default true — a pack is a file that gets committed."),
  },
  async (args) => {
    const { session, path } = await currentSession();
    if (!session.mocks.length) return text(`No rules in ${path} to export.`);

    let scenarios = session.scenarios;
    if (args.group) {
      const needle = args.group.toLowerCase();
      scenarios = scenarios.filter((scenario) => (scenario.group ?? "").toLowerCase() === needle);
      if (!scenarios.length) {
        const groups = [...new Set(session.scenarios.map((scenario) => scenario.group).filter(Boolean))];
        return text(`No scenarios in group “${args.group}”. Known groups: ${groups.join(", ") || "none"}`);
      }
    }

    // Only the rules the exported scenarios actually name. A pack that carried
    // every rule on the device would hand a tester someone else's half-finished
    // experiments along with the thing they asked for.
    const named = new Set(scenarios.flatMap((scenario) => scenario.entries.map((entry) => entry.endpointKey)));
    const selected = args.group ? session.mocks.filter((rule) => named.has(rule.endpointKey)) : session.mocks;
    const mocks = args.redact === false ? selected : selected.map(redacted);

    const base = args.file.split("/").pop()?.replace(/\.networklens-pack\.json$|\.json$/, "") ?? "pack";
    const pack = {
      formatVersion: 1,
      name: args.name ?? base,
      notes: args.notes ?? "",
      createdAt: packDate(undefined),
      mocks,
      scenarios: scenarios.map((scenario) => ({ ...scenario, createdAt: packDate(scenario.createdAt) })),
    };

    try {
      await writeFile(args.file, `${JSON.stringify(pack, null, 2)}\n`, "utf8");
    } catch (error) {
      return text(`Could not write ${args.file}: ${(error as Error).message}`);
    }

    return text(
      [
        `Wrote ${args.file}`,
        `  ${mocks.length} rules · ${scenarios.length} scenarios${args.group ? ` · group ${args.group}` : ""}`,
        args.redact === false ? "  NOT redacted — do not commit this without reading it." : "  redacted: credentials and payment fields removed",
        "Import it anywhere with lens_import_pack, or the overlay's Setups tab.",
      ].join("\n")
    );
  }
);

const transport = new StdioServerTransport();
await server.connect(transport);
