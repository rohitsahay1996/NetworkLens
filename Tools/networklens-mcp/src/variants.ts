import { randomUUID } from "node:crypto";
import { MockRule, MockVariant } from "./session.js";

/** `URLError.timedOut`. The session file stores the raw value, not the case. */
const URL_ERROR_TIMED_OUT = -1001;

const JSON_HEADERS = { "Content-Type": "application/json" };

export function newID(): string {
  return randomUUID().toUpperCase();
}

/**
 * One `MockOutcome.respond` step, in the shape Swift's synthesised `Codable`
 * writes it: the case name, then `_0` for its associated value.
 */
function respond(body: Buffer | string, statusCode: number, headers: Record<string, string>, delay = 0) {
  const data = typeof body === "string" ? Buffer.from(body, "utf8") : body;
  return { respond: { _0: { body: data.toString("base64"), delay, headers, statusCode } } };
}

function fail(errorCode: number, label: string, delay = 0) {
  return { fail: { _0: { errorCode, label, delay } } };
}

export function variant(name: string, steps: unknown[]): MockVariant {
  return { id: newID(), name, steps, exhaustion: "repeatLast" };
}

/**
 * `loaded`, `empty`, `500`, `slow`, `timeout` — the port of `CapturedVariants`.
 *
 * Kept byte-compatible with the Swift side on purpose: a rule written from here
 * and one captured in the overlay have to be the same thing, or a pack exported
 * after a host-side capture would not survive the round trip.
 */
export function standardSet(
  body: Buffer | null,
  statusCode = 200,
  headers: Record<string, string> = JSON_HEADERS,
  slowDelay = 3
): MockVariant[] {
  const captured = body ?? Buffer.alloc(0);
  return [
    variant("loaded", [respond(captured, statusCode, headers)]),
    variant("empty", [respond(emptied(captured), 200, headers)]),
    variant("500", [respond(failed(captured), 500, headers)]),
    variant("slow", [respond(captured, statusCode, headers, slowDelay)]),
    variant("timeout", [fail(URL_ERROR_TIMED_OUT, "timed out")]),
  ];
}

export function ruleFor(endpointKey: string, variants: MockVariant[]): MockRule {
  return {
    id: newID(),
    endpointKey,
    match: { query: {}, headers: {}, bodyContains: null },
    variants,
    activeVariantID: variants[0]?.id ?? newID(),
    isEnabled: false,
  };
}

/**
 * The captured body with its containers emptied and its envelope intact.
 *
 * A bare `{}` is a different response, not an empty one — the app fails to
 * decode it and shows the error state, so the empty state never renders and the
 * variant proves nothing.
 */
export function emptied(body: Buffer): Buffer {
  try {
    return Buffer.from(JSON.stringify(hollow(JSON.parse(body.toString("utf8")))), "utf8");
  } catch {
    return Buffer.from("{}", "utf8");
  }
}

/** Rewrites the app's own envelope rather than inventing an error shape it
 *  does not parse. */
export function failed(body: Buffer, statusCode = 500): Buffer {
  let parsed: unknown;
  try {
    parsed = JSON.parse(body.toString("utf8"));
  } catch {
    return Buffer.from(`{"error":"internal server error"}`, "utf8");
  }
  if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) {
    return Buffer.from(`{"error":"internal server error"}`, "utf8");
  }

  const object = { ...(parsed as Record<string, unknown>) };
  for (const key of Object.keys(object)) {
    switch (key.toLowerCase()) {
      case "code":
        object[key] = statusCode;
        break;
      case "status":
        object[key] = "INTERNAL_SERVER_ERROR";
        break;
      case "data":
      case "value":
      case "result":
      case "payload":
        object[key] = null;
        break;
      default:
        break;
    }
  }
  if (object.errorCode === undefined && object.code !== undefined) object.errorCode = "SYSTEM_ERROR";

  return Buffer.from(JSON.stringify(object), "utf8");
}

function hollow(value: unknown): unknown {
  if (Array.isArray(value)) return [];
  if (value === null || typeof value !== "object") return value;
  const result: Record<string, unknown> = {};
  for (const [key, nested] of Object.entries(value as Record<string, unknown>)) {
    result[key] = hollow(nested);
  }
  return result;
}
