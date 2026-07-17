# MCP Tools

Design of record for Attaché's MCP client support (INF-373, 2026-07-17).
Attaché can connect to MCP servers so a personality can look up information
during a live call without tasking an agent.

## Scope

Lookups, not agentic work. MCP tools extend the existing bounded live-call
tool loop in `AttachePresentationService`: bounded rounds, per-call timeouts,
and a final no-tools round so every call ends in speech. Doing work inside an
agent session remains the two-way Tell Agent path. Attaché does not become a
general agent harness.

## Server registry (global)

- Servers are configured once, app-wide, in a Claude-compatible `mcp.json`
  in the Attache app-support directory. The `mcpServers` object holds stdio
  entries (`command`, `args`, `env`) and remote entries (`url`, `headers`).
- The file is the source of truth and is hand-editable. The app watches it
  and reloads on change; a Settings pane surfaces connection status, tool
  counts, and validation errors over the same file, and can add a server by
  pasting a standard JSON snippet.
- The client is minimal and dependency-free: JSON-RPC 2.0 `initialize`,
  `tools/list`, and `tools/call` over stdio or streamable HTTP (bearer
  headers; JSON or SSE responses), with connect and call timeouts.

## Per-personality tool grants

Each personality carries a tool grant map; servers are shared, capability is
not. The default for every tool is Not offered: the model never sees the
schema. This is both the safety boundary and the context budget mechanism
(an aggregator endpoint can expose hundreds of tools; a 64k-context local
model cannot carry those schemas). Tool names are namespaced
`mcp__server__tool`, matching the Claude Code convention.

## Permissions: three states, no bypass

- **Not offered** (default): schema never sent to the model.
- **Ask first**: offered; the call pauses for a one-tap confirmation, the
  same interaction as the agent-send confirm.
- **Always allow**: runs without a prompt. Available only for read-only
  tools (MCP annotation `readOnlyHint == true`).

Effectful tools are clamped to Ask first permanently; there is no override
and no global bypass mode. The Ask-first confirmation offers "Always allow
for this personality" for read-only tools only. A Private Call offers
read-only tools at most; effectful tools are absent entirely.

## Privacy and egress

Tool results are provenance-labeled like every other context item and flow
through the existing egress accounting: they are context sent to the
personality's model, and the same disclosure rules apply. MCP support must
never weaken the context privacy decisions of record.

## Surfaces

Three UI surfaces (INF-373 phase 2) sit over the phase-1 registry and policy:

- **Settings "MCP Servers" pane** (`MCPServersPane`): the server list with live
  status, tool counts, and validation errors over `mcp.json`. Add a server by
  pasting a snippet, toggle `"enabled"`, open the file, or reload. Config edits
  round-trip through the pure `MCPConfigEditor` (Core).
- **Personality editor Tools picker** (`MCPToolPickerPalette`): a command-style
  palette that groups each server's tools, connects idle servers lazily, and
  cycles a tool's permission by clicking its chip. Grants land in the
  personality's `mcpToolGrants`; effectful tools never reach Always allow.
- **Ask-first approval sheet** (`MCPApprovalSheet`): bound to
  `AppModel.pendingMCPApproval`, it names the tool, server, and character, shows
  the arguments, and offers Deny / Allow Once / (read-only only) Always allow.
  Hanging up resolves any pending approval as deny.
