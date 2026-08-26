import { execFile } from "node:child_process";
import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";

const run = promisify(execFile);

const TRACE_RELATIVE_PATH = join("Library", "Application Support", "NetworkLens", "trace.ndjson");

/**
 * Where the trace is, in precedence order.
 *
 * NETWORKLENS_TRACE wins because a device trace pulled off with Xcode lands
 * wherever the person put it, and no amount of guessing finds that.
 */
export async function resolveTracePath(): Promise<{ path: string; how: string }> {
  const explicit = process.env.NETWORKLENS_TRACE;
  if (explicit) return { path: explicit, how: "NETWORKLENS_TRACE" };

  const bundleId = process.env.NETWORKLENS_BUNDLE_ID;
  if (bundleId) {
    const container = await bootedAppContainer(bundleId);
    if (container) {
      return { path: join(container, TRACE_RELATIVE_PATH), how: `simctl container for ${bundleId}` };
    }
  }

  // A macOS host app, or the package's own tests.
  return {
    path: join(homedir(), "Library", "Application Support", "NetworkLens", "trace.ndjson"),
    how: "host Application Support",
  };
}

/**
 * Data container of an app installed on the booted simulator.
 *
 * `simctl` returns the *data* container, which is the one holding Application
 * Support — the bundle container next to it has no writable trace in it.
 */
export async function bootedAppContainer(bundleId: string): Promise<string | null> {
  try {
    const { stdout } = await run("xcrun", ["simctl", "get_app_container", "booted", bundleId, "data"]);
    const path = stdout.trim();
    return path && existsSync(path) ? path : null;
  } catch {
    return null;
  }
}
