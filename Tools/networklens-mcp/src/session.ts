import { readFile, writeFile, rename } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import { bootedAppContainer, isAppRunning } from "./container.js";

const SESSION_RELATIVE_PATH = join("Library", "Application Support", "NetworkLens", "session.json");

/** The rules file the app reads at `start()` and autosaves back to. */
export interface Session {
  mocks: MockRule[];
  scenarios: Scenario[];
  breakpoints?: unknown[];
  perturbations?: unknown[];
  isMockingEnabled?: boolean;
}

export interface MockRule {
  id: string;
  endpointKey: string;
  match: MockMatch;
  variants: MockVariant[];
  activeVariantID: string;
  isEnabled: boolean;
}

export interface MockMatch {
  query?: Record<string, string>;
  headers?: Record<string, string>;
  bodyContains?: string | null;
}

export interface MockVariant {
  id: string;
  name: string;
  steps: unknown[];
  exhaustion?: unknown;
  requestSample?: string | null;
}

export interface Scenario {
  id: string;
  name: string;
  createdAt: string;
  entries: ScenarioEntry[];
  /** Optional since packs predate grouping — a scenario without one is loose
   *  in the list rather than under a heading. */
  group?: string;
}

export interface ScenarioEntry {
  endpointKey: string;
  match: MockMatch;
  variantID: string;
  variantName: string;
  isEnabled: boolean;
}

/**
 * Where the rules live, mirroring `resolveTracePath`.
 *
 * NETWORKLENS_SESSION exists for the same reason NETWORKLENS_TRACE does: a
 * container pulled off a device lands wherever the person put it.
 */
export async function resolveSessionPath(): Promise<{ path: string; how: string }> {
  const explicit = process.env.NETWORKLENS_SESSION;
  if (explicit) return { path: explicit, how: "NETWORKLENS_SESSION" };

  const bundleId = process.env.NETWORKLENS_BUNDLE_ID;
  if (bundleId) {
    const container = await bootedAppContainer(bundleId);
    if (container) {
      return { path: join(container, SESSION_RELATIVE_PATH), how: `simctl container for ${bundleId}` };
    }
  }

  return {
    path: join(homedir(), "Library", "Application Support", "NetworkLens", "session.json"),
    how: "host Application Support",
  };
}

/** An absent file reads as an empty session: the app writes it on first edit,
 *  so "no rules yet" and "not installed" look the same from here and both are
 *  answered the same way — write one. */
export async function readSession(path: string): Promise<Session> {
  try {
    const raw = await readFile(path, "utf8");
    const parsed = JSON.parse(raw) as Partial<Session>;
    return {
      mocks: parsed.mocks ?? [],
      scenarios: parsed.scenarios ?? [],
      breakpoints: parsed.breakpoints ?? [],
      perturbations: parsed.perturbations ?? [],
      isMockingEnabled: parsed.isMockingEnabled ?? false,
    };
  } catch {
    return { mocks: [], scenarios: [], breakpoints: [], perturbations: [], isMockingEnabled: false };
  }
}

/** Atomic, because the app reads this file at launch and a half-written one
 *  presents as every rule having vanished. */
export async function writeSession(path: string, session: Session): Promise<void> {
  const temporary = `${path}.mcp-tmp`;
  await writeFile(temporary, `${JSON.stringify(session, null, 2)}\n`, "utf8");
  await rename(temporary, path);
}

/** Seconds between the Unix epoch and Swift's reference date, 2001-01-01. */
const SWIFT_REFERENCE_EPOCH = 978_307_200;

/**
 * A `Date` as `session.json` stores it: a number.
 *
 * The pack format writes ISO-8601 strings, which is right for a file people
 * read in a diff. `FileSnapshotStore` does not — it decodes with a plain
 * `JSONDecoder`, whose default strategy expects `timeIntervalSinceReferenceDate`
 * as a double. Writing the string form into the session file makes the decode
 * throw, and `load()` swallows that with `try?`, so the app silently starts with
 * no rules at all rather than complaining. Converting on the way in is the whole
 * fix, and it has to happen for every date the pack carries.
 */
export function toSnapshotDate(value: unknown): number {
  if (typeof value === "number") return value;
  if (typeof value === "string") {
    const parsed = Date.parse(value);
    if (!Number.isNaN(parsed)) return parsed / 1000 - SWIFT_REFERENCE_EPOCH;
  }
  return Date.now() / 1000 - SWIFT_REFERENCE_EPOCH;
}

export function sameRule(a: { endpointKey: string; match: MockMatch }, b: { endpointKey: string; match: MockMatch }): boolean {
  return a.endpointKey === b.endpointKey && JSON.stringify(normalise(a.match)) === JSON.stringify(normalise(b.match));
}

/** Identity is the key-and-match pair, so the comparison has to survive an
 *  absent `query` on one side and an empty object on the other. */
function normalise(match: MockMatch | undefined): MockMatch {
  return {
    query: match?.query ?? {},
    headers: match?.headers ?? {},
    bodyContains: match?.bodyContains ?? null,
  };
}

export function findVariant(rule: MockRule, name: string): MockVariant | undefined {
  const needle = name.trim().toLowerCase();
  return (
    rule.variants.find((variant) => variant.name.toLowerCase() === needle) ??
    rule.variants.find((variant) => variant.name.toLowerCase().includes(needle))
  );
}

export function findRule(session: Session, endpoint: string): MockRule | undefined {
  const needle = endpoint.trim().toLowerCase();
  return (
    session.mocks.find((rule) => rule.endpointKey.toLowerCase() === needle) ??
    session.mocks.find((rule) => rule.endpointKey.toLowerCase().includes(needle))
  );
}

export function findScenario(session: Session, name: string): Scenario | undefined {
  const needle = name.trim().toLowerCase();
  return (
    session.scenarios.find((scenario) => scenario.name.toLowerCase() === needle) ??
    session.scenarios.find((scenario) => scenario.name.toLowerCase().includes(needle))
  );
}

/**
 * The sentence every write tool ends on.
 *
 * The app reads this file at `start()` and autosaves over it on each edit, so a
 * write while it runs is both invisible and doomed. Saying so every time is the
 * difference between a tool that works and one that looks broken.
 */
export const RELAUNCH_NOTE =
  "Launch the app to pick this up — rules are read at launch.";

/**
 * Refuses a write while the app is running, and says why in the order the steps
 * have to happen in.
 *
 * The earlier wording — "quit and relaunch" — was read as an instruction for
 * afterwards, which is exactly backwards: the write has to land while the app
 * is stopped, or its autosave wins. Returning the reason as a string rather
 * than throwing keeps it a normal tool result the model can act on.
 */
export async function blockedByRunningApp(): Promise<string | null> {
  const bundleId = process.env.NETWORKLENS_BUNDLE_ID;
  if (!bundleId || process.env.NETWORKLENS_SESSION) return null;
  if (!(await isAppRunning(bundleId))) return null;
  return [
    `${bundleId} is running, and it owns this file while it lives — it would overwrite this write within seconds.`,
    "",
    "Order matters:",
    `  1. quit the app  (xcrun simctl terminate booted ${bundleId})`,
    "  2. run this tool again",
    "  3. launch the app",
  ].join("\n");
}
