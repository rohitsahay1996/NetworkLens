#!/bin/sh
# Launcher for the networklens MCP server, referenced by the app repo's .mcp.json.
#
# The build output is deliberately not committed, so the first launch on a fresh
# clone has to produce it. Doing that here rather than asking the developer to
# remember an npm step is the whole point: an MCP client launches this with no
# terminal attached, and a missing dist/ would surface only as "the server won't
# connect" with nothing to read.
#
# Everything diagnostic goes to stderr — stdout is the JSON-RPC channel and any
# stray line on it desynchronises the client.
set -e
DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$DIR"

if [ ! -f dist/index.js ] || [ src/index.ts -nt dist/index.js ]; then
    echo "networklens-mcp: building…" >&2
    if [ -d node_modules ]; then
        npm run build >&2
    else
        # `ci` not `install`, so the lockfile is the source of truth and a stale
        # node_modules can never silently change what the server is running.
        npm ci >&2 && npm run build >&2
    fi
fi

exec node dist/index.js
