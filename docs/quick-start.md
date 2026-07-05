# Quick start

Five minutes from download to your first spoken update.

## 1. Install

Download `Attache.zip` from [Releases](https://github.com/danbryan/attache/releases),
unzip, drag `Attache.app` to `/Applications`, open it. It is signed and
notarized; macOS opens it without warnings.

Building from source instead: `git clone`, then `swift run Attache`. No Apple
certificates needed.

## 2. Finish onboarding

The four-step onboarding picks a voice, a personality, and asks which agent
sources to enable (Codex, Claude Code). Enable the ones you use. Nothing is
read until you turn a source on.

## 3. Hear it work

No agent session handy? Send a simulated event from the repo:

```bash
scripts/send-event.sh
```

You should hear a spoken recap, see word-synced captions, and find a new card
in the inbox.

## 4. Point it at real work

Start a Codex or Claude Code session, then press **⌘K** in Attaché and pin the
session. From now on every completed turn arrives as a spoken update and a
replayable card. Attaché only ever narrates sessions you pin.

## 5. The two settings that matter

- **Voice**: download a free macOS Premium voice (System Settings →
  Accessibility → Spoken Content → Manage Voices, grab Ava or Zoe), then select
  it in **Settings → Voice & Captions**. Massive upgrade, zero cost.
- **Personality**: give it a text brain in **Settings → Model** (free local
  option: [Ollama](https://ollama.com) with `qwen3`), then pick or write a
  persona in **Settings → Personalities**. Tone, attitude, detail level, even
  the language it speaks are yours to define.

## Keys worth learning

| Key | Does |
| --- | --- |
| Space | Play or pause the selected card |
| S / D / R | Slower, faster, reset playback speed |
| ⌘K | Find and pin sessions |
| ⌘I | Inbox |
| ⌘Y | Companion history |
| ⌘L | Start or end a voice conversation |
| ⌘/ | All shortcuts |

## Next

- [The Attaché mindset](mindset.md), why this is not another dashboard
- [README](../README.md), the full tour: privacy model, configuration, event bridge
- [CONTRIBUTING](../CONTRIBUTING.md), share a personality or theme you made
