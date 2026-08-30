# Vendored from the NetworkLens package

`tools/networklens/`, `tools/networklens-mcp/` and the three skills under
`BlibliMobile-iOS/.claude/skills/` are copies of `NetworkLens/{Tools,Skills}/`
in `gdncomm/BlibliLogger`. The package is the upstream; this repo carries the
copy so a developer gets working tooling from a plain `git pull`.

| Field | Value |
|---|---|
| Source repo | gdncomm/BlibliLogger |
| Source path | `NetworkLens/Tools`, `NetworkLens/Skills/networklens` |
| Vendored from | `14.4.1` (pre-tag working tree at time of migration) |
| Vendored on | 2026-08-27 |

Re-sync with the `networklens-setup` skill's upgrade step, never by hand-editing
one side only. If you fix something here, port it upstream in the same PR.
