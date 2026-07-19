# Third-party integrations (Tier 0)

Attaché watches OpenAI Codex and Claude Code with zero setup. Any other CLI
tool, script, or harness can plug in the same way those two do: by posting a
JSON event to Attaché's local event server. This is "Tier 0" integration:
there is no plugin API and nothing to install in Attaché, just an HTTP POST.

## What Tier 0 integration gives you

- **A narrated voicemail card.** Each event you post becomes a card in the
  Inbox, summarized and spoken in the active personality's voice, with
  word-synced captions.
- **Playback.** The card can be played, paused, sought, and replayed like any
  other card, and marked heard via the API described below.
- **Recap inclusion.** The event is eligible for inclusion when Attaché
  produces a spoken recap of recent activity.

## What Tier 0 integration does not give you

- **No live transcript tail.** Attaché's `CodexSessionWatcher` polls a pinned
  agent's on-disk session transcript directly; a Tier 0 integration only ever
  sends discrete events, so it cannot participate in transcript-following
  behavior, and there is nothing to "pin."
- **No activity phrases.** The interstitial "what the agent is doing right
  now" ticker (`SessionActivityWatcher`) is driven by Codex/Claude Code session
  polling, not by posted events.
- **No two-way replies.** A Tier 0 event is one-directional (your tool to
  Attaché). Attaché's reverse-send / two-way instruction channel
  (`docs/two-way.md`) is scoped to the two supported agent sources
  (`codex`, `claude_code`); a Tier 0 `source` cannot receive a reply.

If you need those, your integration is not Tier 0 and is out of scope for this
document.

## The endpoint

```
POST http://127.0.0.1:7531/events
GET  http://127.0.0.1:7531/health
```

The server binds loopback only (`127.0.0.1`); it is not reachable from another
machine or container. It rejects any request that carries an `Origin` header
or a non-loopback `Host` header, so a browser page cannot reach it either
(anti DNS-rebinding). It is per-launch: the port stays `7531`, but the token
below changes every time Attaché starts.

### The token

Every launch, Attaché writes a fresh bearer token to:

```
~/Library/Application Support/Attache/event-token
```

The file is created with mode `0600` (owner read/write only). Read it fresh
each time you post; do not cache it across an Attaché relaunch, and never
commit it or log it anywhere. Send it as a standard bearer header:

```
Authorization: Bearer <token>
```

`GET /health` does not require the token, so integrators can probe liveness
without it. Every other route does.

## Request

```bash
TOKEN="$(cat "$HOME/Library/Application Support/Attache/event-token")"

curl -sS -X POST http://127.0.0.1:7531/events \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $TOKEN" \
  --data-binary @- <<'JSON'
{
  "source": "my-cli-tool",
  "event_type": "assistant.completed",
  "external_session_id": "run-42",
  "project_path": "/Users/you/code/my-project",
  "title": "Deploy finished",
  "text": "The deploy script finished and the service passed its health check.",
  "metadata": {
    "exit_code": "0"
  }
}
JSON
```

### Response

```json
{"status":"accepted"}
```

with HTTP status `202 Accepted`.

## Event fields

The body is a single JSON object. This is the complete, authoritative field
list; it is generated from `NormalizedEvent.CodingKeys` in
`Sources/AttacheCore/Models.swift` and a doc-drift test
(`Tests/AttacheCoreTests/EventSchemaDocTests.swift`) fails the build if this
table and that source of truth diverge. Do not add fields beyond this list;
Attaché ignores unrecognized JSON keys, it does not reject them.

**"Required key" below means the JSON key itself must be present** (its
value may still be an empty string, where noted) **because `NormalizedEvent`
decodes with plain `Codable` synthesis: a non-optional field with a missing
key fails the whole decode**, not just that field. That failure is currently
silent at the HTTP layer (see Errors below): a request missing a required
key still gets `202 Accepted`, then the event is dropped inside the app.
Always send every required key.

| Field                 | Type           | Required | Notes |
| --------------------- | -------------- | -------- | ----- |
| `source`               | string         | **required key** | Identifies your integration, e.g. `"my_cli_tool"`. The key must be present; its value may be `""`, which becomes `"generic"`. Any string is accepted; there is no allowlist. For an unknown source, `CardStore.displayName` capitalizes the first letter of each `_`-delimited segment for display (e.g. `my_cli_tool` becomes "My Cli Tool"; a source with no underscores, e.g. `mybuild`, becomes "Mybuild", only its first letter capitalized — hyphens are not split on). Prefer underscores over hyphens in `source` if you want a clean display name. |
| `event_type`           | string         | **required key** | A free-form event kind, e.g. `"assistant.completed"`. The key must be present; its value may be `""`, which becomes `"assistant.completed"`. |
| `external_session_id`  | string or null | optional | Your own identifier for the run or session this event belongs to. May be omitted entirely, or `null`. Blank/whitespace-only is also treated as absent. |
| `project_path`         | string or null | optional | Filesystem path shown alongside the card title. May be omitted entirely, or `null`. Blank/whitespace-only is also treated as absent. |
| `title`                | string         | **required key** | Short heading for the card. The key must be present; its value may be `""`, which becomes `"Agent update"`. |
| `text`                 | string         | **required key, required value** | The event body. The key must be present, and unlike the fields above, an empty or whitespace-only value is rejected too, with no fallback (see Errors below). |
| `metadata`             | object of string to string | **required key** | Free-form key/value strings. The key must be present; its value may be `{}`. Two entries are read specially if present, letting your integration control narration precisely instead of relying on Attaché's automatic summarizer: `attache_summary` (or `card_summary`) overrides the card's short summary, and `attache_spoken_text` (or `spoken_text`) overrides what gets spoken. Every other metadata key is stored but not otherwise interpreted by Attaché for a third-party source. |
| `schema_version`       | integer        | optional | See Schema version below. May be omitted entirely; absent means `1`. |

### Size limits

The server caps the request body at **1,000,000 bytes**. A request that
declares a `Content-Length` larger than that is rejected with `413` before
its body is read. A request without a usable `Content-Length` that still
grows past the cap while streaming is rejected with `400 Bad Request` instead
(the server never buffers more than the cap either way). There is no separate
per-field limit beyond that overall cap. Always send `Content-Length` (any
normal HTTP client, including `curl`, does this for you).

### Schema version

`schema_version` is an explicit, optional integer field added so this
contract can evolve without silently breaking existing integrations.

- Omit it, or send `"schema_version": 1`: today's field list (above) applies.
- Send a higher version this build doesn't understand (e.g. `2`, before a
  future release adds it) and the request is rejected with `400 Bad Request`
  before anything is stored, naming the version this server supports:

  ```json
  {"error":"Unsupported schema_version 2; this server supports schema_version 1."}
  ```

This is the only field whose value is checked synchronously before the
server responds; every other validation happens after the `202 Accepted` you
already received (see Errors below), because narration happens off the
request path.

## Errors

| Status | Body | When |
| ------ | ---- | ---- |
| `401 Unauthorized` | `{"error":"missing or invalid token; read ~/Library/Application Support/Attache/event-token"}` | Missing, wrong, or malformed `Authorization` header. |
| `413 Payload Too Large` | `{"error":"body too large"}` | Declared or actual body exceeds 1,000,000 bytes. |
| `400 Bad Request` | `{"error":"Unsupported schema_version <n>; this server supports schema_version 1."}` | `schema_version` names a version above what this server supports. |
| `400 Bad Request` | `{"error":"invalid request"}` | The HTTP request itself is malformed (bad request line, truncated headers, or the connection closed mid-request). |
| `403 Forbidden` | `{"error":"forbidden"}` | Request carried an `Origin` header, or a `Host` header that isn't loopback (anti DNS-rebinding). |
| `503 Service Unavailable` | `{"error":"too many connections"}` | More than 16 connections are being handled at once. |

A well-formed HTTP request whose JSON body is otherwise malformed (bad JSON,
or valid JSON missing the required `text` field) is still accepted with
`202 Accepted` at the HTTP layer; Attaché decodes and validates it
asynchronously inside the app after responding, and a failure there surfaces
only in the app's own intake status, not in the HTTP response. Sending
`schema_version` is the one way to get a synchronous `400` for a bad payload
today. Keep your integration's JSON well-formed and always include `text`.

## Health

```bash
curl -sS http://127.0.0.1:7531/health
```

```json
{"status":"ok","bind":"127.0.0.1","port":7531}
```

No token required. Use this to check Attaché is running before posting an
event, or to discover the bound port if you started Attaché with a
non-default one.

## Worked example: wrapping an arbitrary CLI tool

Say you have a build tool, `mybuild`, and you want its completion to show up
as an Attaché card. Wrap the invocation in a small shell function:

```bash
notify_attache() {
  local title="$1" text="$2" ok="$3"
  local token_file="$HOME/Library/Application Support/Attache/event-token"
  [ -f "$token_file" ] || return 0   # Attaché not running; skip quietly
  local token
  token="$(cat "$token_file")"
  curl -sS -X POST http://127.0.0.1:7531/events \
    -H 'Content-Type: application/json' \
    -H "Authorization: Bearer $token" \
    --data-binary @- <<JSON
{
  "source": "mybuild",
  "event_type": "$([ "$ok" = "1" ] && echo build.succeeded || echo build.failed)",
  "external_session_id": "$$",
  "project_path": "$(pwd)",
  "title": "$title",
  "text": "$text",
  "metadata": {
    "exit_code": "$ok"
  }
}
JSON
}

if mybuild; then
  notify_attache "Build finished" "mybuild completed successfully." 1
else
  notify_attache "Build failed" "mybuild exited with an error." 0
fi
```

Run it, and a card titled "Build finished" (or "Build failed") shows up in
Attaché's Inbox, narrated in your active personality's voice. See
`scripts/send-event.sh` in this repo for a minimal, runnable reference
implementation of the same pattern.

## Reference implementation

`scripts/send-event.sh` in this repository is a working example: it reads the
token file, builds the same JSON shape documented above, and posts it with
`curl`. Run it against a locally running Attaché to see a card land:

```bash
scripts/send-event.sh
```
