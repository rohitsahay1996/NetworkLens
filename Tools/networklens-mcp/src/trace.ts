import { readFile, stat } from "node:fs/promises";

/** Mirrors NetworkLensCore's TraceRecord. Kept structural on purpose — a trace
 *  written by a newer build must still read here rather than throw. */
export interface TraceRecord {
  schema: number;
  sessionID: string;
  recordedAt: string;
  exchange: Exchange;
}

export interface Snapshot {
  method?: string;
  url?: string;
  statusCode?: number;
  headers?: Record<string, string>;
  body?: string | null;
  bodyTruncated?: boolean;
  originalBodyByteCount?: number | null;
  mimeType?: string | null;
}

export interface Exchange {
  id: string;
  endpointKey: string;
  screen?: string | null;
  request: Snapshot;
  response?: Snapshot | null;
  failure?: { statusCode?: number; kind?: string } | null;
  timing?: Record<string, number> | null;
  startedAt: string;
  source?: unknown;
  isMockServed?: boolean;
  replayOf?: string | null;
  edits?: unknown[];
}

/** An exchange plus what the trace knows about it beyond its own fields. */
export interface Entry {
  exchange: Exchange;
  sessionID: string;
  recordedAt: string;
  /** Lines seen for this id. >1 means it was edited after it completed. */
  revisions: number;
}

export class TraceReadError extends Error {}

/**
 * Reads the whole file rather than tailing it.
 *
 * A trace is bounded by TraceWriter's rotation, and every query wants a
 * different slice of it, so caching a parse keyed on mtime+size beats holding a
 * stream open and guessing which window a caller will ask for next.
 */
export class Trace {
  private cache?: { key: string; entries: Entry[] };

  constructor(readonly path: string) {}

  async entries(): Promise<Entry[]> {
    let info;
    try {
      info = await stat(this.path);
    } catch {
      throw new TraceReadError(
        `No trace at ${this.path}. Is NetworkLens started with a trace option, and has the app made a request yet?`
      );
    }

    const key = `${info.mtimeMs}:${info.size}`;
    if (this.cache?.key === key) return this.cache.entries;

    const text = await readFile(this.path, "utf8");
    const entries = collapse(parse(text));
    this.cache = { key, entries };
    return entries;
  }
}

/** A process killed mid-write leaves a partial last line; skip it rather than
 *  failing the whole read. */
export function parse(text: string): TraceRecord[] {
  const out: TraceRecord[] = [];
  for (const line of text.split("\n")) {
    if (!line.trim()) continue;
    try {
      out.push(JSON.parse(line) as TraceRecord);
    } catch {
      continue;
    }
  }
  return out;
}

/** Last line for an id wins — TraceWriter appends on every edit rather than
 *  rewriting, so earlier lines are history, not the current state. */
export function collapse(records: TraceRecord[]): Entry[] {
  const byId = new Map<string, Entry>();
  for (const record of records) {
    const existing = byId.get(record.exchange.id);
    byId.set(record.exchange.id, {
      exchange: record.exchange,
      sessionID: record.sessionID,
      recordedAt: record.recordedAt,
      revisions: (existing?.revisions ?? 0) + 1,
    });
  }
  return [...byId.values()];
}

export function decodeBody(body?: string | null): Buffer | null {
  if (!body) return null;
  return Buffer.from(body, "base64");
}

export function durationMs(exchange: Exchange): number | null {
  const timing = exchange.timing;
  if (!timing) return null;
  const total = timing.total ?? timing.duration ?? timing.elapsed;
  return typeof total === "number" ? Math.round(total * 1000) : null;
}

export function statusOf(exchange: Exchange): string {
  if (exchange.response?.statusCode) return String(exchange.response.statusCode);
  if (exchange.failure) return exchange.failure.kind ?? "failed";
  return "—";
}

/**
 * Resolve a JSON Pointer (RFC 6901) against a parsed body.
 *
 * The whole point of the body tools: a 1MB response read whole is useless in a
 * model's context, and `/data/items/0` is what the question was actually about.
 */
export function resolvePointer(value: unknown, pointer: string): unknown {
  if (!pointer || pointer === "/") return value;
  let current: unknown = value;
  for (const rawToken of pointer.replace(/^\//, "").split("/")) {
    const token = rawToken.replace(/~1/g, "/").replace(/~0/g, "~");
    if (current === null || current === undefined) return undefined;
    if (Array.isArray(current)) {
      const index = Number(token);
      if (!Number.isInteger(index)) return undefined;
      current = current[index];
    } else if (typeof current === "object") {
      current = (current as Record<string, unknown>)[token];
    } else {
      return undefined;
    }
  }
  return current;
}

/** Walks a parsed body collecting pointers whose key or scalar value matches. */
export function searchBody(
  value: unknown,
  needle: string,
  pointer = "",
  hits: { pointer: string; snippet: string }[] = [],
  limit = 50
): { pointer: string; snippet: string }[] {
  if (hits.length >= limit) return hits;
  const lowered = needle.toLowerCase();

  if (value !== null && typeof value === "object") {
    const entries = Array.isArray(value)
      ? value.map((item, index) => [String(index), item] as const)
      : Object.entries(value as Record<string, unknown>);

    for (const [key, child] of entries) {
      const childPointer = `${pointer}/${key.replace(/~/g, "~0").replace(/\//g, "~1")}`;
      if (key.toLowerCase().includes(lowered)) {
        hits.push({ pointer: childPointer, snippet: preview(child) });
      }
      searchBody(child, needle, childPointer, hits, limit);
      if (hits.length >= limit) break;
    }
    return hits;
  }

  if (String(value).toLowerCase().includes(lowered)) {
    hits.push({ pointer: pointer || "/", snippet: preview(value) });
  }
  return hits;
}

export function preview(value: unknown, max = 120): string {
  const text = typeof value === "string" ? value : JSON.stringify(value);
  if (text === undefined) return "undefined";
  return text.length > max ? `${text.slice(0, max)}…` : text;
}
