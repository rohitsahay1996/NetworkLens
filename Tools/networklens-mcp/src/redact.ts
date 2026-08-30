import { MockRule } from "./session.js";

/**
 * The export-side port of `DefaultRedactor`.
 *
 * Bodies captured through the overlay are already redacted on the way into the
 * trace, so this is not a second pass on them — it is the only pass on anything
 * authored host-side (`lens_set_variant_body --file`), and packs get committed.
 * Same header names, same key terms, same tokenizer as the Swift side, so a
 * pack exported from here and one exported from the device hide the same
 * fields.
 */
const HEADER_NAMES = new Set(["authorization", "cookie", "set-cookie", "x-api-key"]);
const BODY_KEY_TERMS = ["card", "cvv", "pan", "password", "token", "secret"];
const PLACEHOLDER = "<redacted>";

/** Tokenised on camelCase, `_`, `-`, `.`, space and digit boundaries, so
 *  `company` and `japan` do not match `pan` while `cardNumber` and `cvv2` do. */
export function tokenize(key: string): string[] {
  const tokens: string[] = [];
  let current = "";
  let previous: string | undefined;

  const flush = () => {
    if (current) tokens.push(current.toLowerCase());
    current = "";
  };

  for (const character of key) {
    const isUpper = character >= "A" && character <= "Z";
    const isDigit = character >= "0" && character <= "9";
    const previousUpper = previous !== undefined && previous >= "A" && previous <= "Z";
    const previousDigit = previous !== undefined && previous >= "0" && previous <= "9";

    if (character === "_" || character === "-" || character === "." || character === " ") {
      flush();
    } else if (previous !== undefined && isUpper && !previousUpper) {
      flush();
      current += character;
    } else if (previous !== undefined && isDigit && !previousDigit) {
      flush();
      current += character;
    } else {
      current += character;
    }
    previous = character;
  }
  flush();
  return tokens;
}

export function isSensitive(key: string): boolean {
  const lower = key.toLowerCase();
  if (HEADER_NAMES.has(lower)) return true;
  return tokenize(key).some((token) => BODY_KEY_TERMS.some((term) => token.startsWith(term)));
}

function redactValue(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(redactValue);
  if (value === null || typeof value !== "object") return value;
  const result: Record<string, unknown> = {};
  for (const [key, nested] of Object.entries(value as Record<string, unknown>)) {
    result[key] = isSensitive(key) ? PLACEHOLDER : redactValue(nested);
  }
  return result;
}

function redactHeaders(headers: Record<string, string> | undefined): Record<string, string> {
  const result: Record<string, string> = {};
  for (const [key, value] of Object.entries(headers ?? {})) {
    result[key] = HEADER_NAMES.has(key.toLowerCase()) ? PLACEHOLDER : value;
  }
  return result;
}

function redactBody(base64: string | undefined): string | undefined {
  if (!base64) return base64;
  const raw = Buffer.from(base64, "base64");
  try {
    const redacted = redactValue(JSON.parse(raw.toString("utf8")));
    return Buffer.from(JSON.stringify(redacted), "utf8").toString("base64");
  } catch {
    // Not JSON — an image, a protobuf, HTML. There is no key structure to walk,
    // and blanking the whole body would make the variant useless, so it goes
    // out as captured.
    return base64;
  }
}

/** A copy of the rule with credentials and payment fields removed. */
export function redacted(rule: MockRule): MockRule {
  return {
    ...rule,
    variants: rule.variants.map((variant) => ({
      ...variant,
      requestSample: variant.requestSample ? redactBody(variant.requestSample) : variant.requestSample,
      steps: variant.steps.map((step) => {
        const respond = (step as { respond?: { _0?: Record<string, unknown> } }).respond;
        if (!respond?._0) return step;
        return {
          respond: {
            _0: {
              ...respond._0,
              headers: redactHeaders(respond._0.headers as Record<string, string> | undefined),
              body: redactBody(respond._0.body as string | undefined),
            },
          },
        };
      }),
    })),
  };
}
