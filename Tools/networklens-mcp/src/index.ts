#!/usr/bin/env node
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import { resolveTracePath } from "./container.js";
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

const transport = new StdioServerTransport();
await server.connect(transport);
