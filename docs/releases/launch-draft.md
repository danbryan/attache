# Launch release notes (DRAFT)

> DRAFT. This is a launch-day summary of the full feature set, not a finalized
> release. The final filename and version number are Dan's call: the public repo
> may restart at `0.1.0` or ship as `1.0.0`. Rename this file to
> `docs/releases/vX.Y.Z.md` and set the version headline once that is decided.

Attaché gives your AI agents a voice. It runs quietly in the background, watches
the agents working for you, and tells you what happened out loud, in a voice and
personality you choose, so you can ship the next thing instead of babysitting a
terminal.

## What's new

- **Four agents, watched and answerable.** Attaché narrates live turns from Codex
  CLI, Claude Code, Grok Build, and opencode with zero setup, and lets you reply
  to any of them. **Tell Agent** sends your direction straight into the running
  session; every send names its target session and asks first.
- **Voicemail for your agents.** Every completed turn becomes a card you can
  replay, skip, and catch up on in one pass, with word-synced karaoke captions
  and an audio visualizer.
- **Spoken recaps.** Ask for a recap of a session and Attaché summarizes it out
  loud, with length scaled to how much happened and captions in sync. Replay any
  recap on demand.
- **Another take.** Re-narrate any card or turn in a different personality's
  voice: it reacts to the prior take, then gives its own spin. Narration only, it
  never re-sends anything to an agent.
- **Interrupts only when it matters.** A real macOS notification arrives when an
  agent is actually blocked on you. Everything else waits in the inbox.
- **History with a cost preview.** Browse historic session summaries and see the
  cost before you spend a token generating one.
- **Live calls.** Start a live conversation to ask Attaché about a focused
  session, or switch to Tell Agent to push direction back in real time.
- **Personalities are one unit.** Each personality owns its brain (prompt and
  preferred model), its voice, its visual presence, its reasoning level, playback
  pace, and an ordered list of live-call fallback providers. Switch personalities
  and the whole loadout changes together.
- **Tools per personality, ask-first.** Attach MCP tools to a personality with
  ask-first approvals so nothing runs without your say-so, and import server
  definitions straight from your other agents' configs (Claude Code, Codex, Grok
  Build, opencode) instead of retyping them.
- **A studio voice that runs on your Mac.** Attaché ships its own premium
  on-device voice, Azelma. It is a one-time download that then runs entirely
  locally, with no account or network needed to speak.
- **Private by design.** Local model plus on-device voice means nothing leaves
  your Mac. Any cloud model or voice provider is opt-in, with explicit consent
  and a clear statement of what gets sent. Each durable memory carries its own
  egress setting. Private calls keep a conversation in memory only and erase it at
  hangup. There is no telemetry.
- **Back up, restore, reset.** Settings → About → Data backs up your
  personalities, history, settings, and watched sessions to a single file (API
  keys are never included, the downloaded voice is optional), restores from one,
  or resets Attaché to a newly installed state.

## The premium voice download

Attaché's on-device voice, Azelma, is a one-time download of about 113 MB. Once
installed it runs entirely on your Mac, offline, with no account. It is licensed
under CC BY and credited in `THIRD-PARTY-LICENSES`. You can include or exclude
the downloaded voice when you back up your profile.

## Requirements

- macOS 13 (Ventura) or later
- Apple Silicon
- Signed with a Developer ID, notarized, and stapled

## Install

Download `Attache.dmg` and drag Attaché to Applications, or:

```
brew install --cask danbryan/tap/attache
```
