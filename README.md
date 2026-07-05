<p align="center">
  <img src="docs/assets/attache-logo.svg" width="130" alt="Attaché logo">
</p>

<h1 align="center">Attaché</h1>

<p align="center"><b>Your AI agents, out loud.</b></p>

<p align="center">
  A native macOS app that watches the AI agents working for you and tells you
  what happened, out loud, in a voice and personality you choose. So you can
  ship the next thing instead of babysitting a terminal.
</p>

<p align="center">
  <img alt="macOS 13+" src="https://img.shields.io/badge/macOS-13%2B-0F1424">
  <img alt="signed & notarized" src="https://img.shields.io/badge/signed%20%26%20notarized-30EAE0">
  <img alt="license FSL-1.1" src="https://img.shields.io/badge/license-FSL--1.1-0A84FF">
</p>

<p align="center">
  <a href="https://youtu.be/G0xXOal4e4U">
    <img src="docs/assets/screenshot-play.png" width="720" alt="Watch the 2-minute tour">
  </a>
  <br>
  <b><a href="https://youtu.be/G0xXOal4e4U">▶ Watch the 2-minute tour</a></b>
</p>

---

## What it does

- **Speaks every result.** When an agent finishes a turn, Attaché says what it
  did, with word-synced captions and an audio visualizer.
- **Files it like voicemail.** Every update becomes a card you can replay, skip,
  and catch up on in one pass.
- **Interrupts only when it matters.** A real macOS notification when an agent is
  actually blocked on you. Everything else waits.
- **Go live.** Talk to it in real time: ask about a running session, and push new
  direction back to your agents.
- **You pick the voice and the vibe.** Any voice (on-device, ElevenLabs, xAI,
  OpenAI) and any personality, from a one-line brief to a warm explainer.

It watches [OpenAI Codex](https://openai.com/codex/) and
[Claude Code](https://www.anthropic.com/claude-code) with zero setup, and only
speaks about sessions you pin.

## Download & run

Grab the signed, notarized build. No account, no build tools.

1. Download **[Attache.dmg](https://github.com/danbryan/attache/releases/latest/download/Attache.dmg)**.
2. Open it and drag **Attaché** to your Applications folder.
3. Launch it. macOS opens it cleanly (it's notarized).

Prefer to build it yourself? `git clone` this repo and run `swift run Attache`.
No Apple certificates needed.

## Quick start

1. Finish the two-minute onboarding: pick a **voice**, a **personality**, a
   **model**, and which agents it may watch.
2. Start a Codex or Claude Code session, press **⌘K**, and pin it.
3. That's it. Every completed turn now arrives as a spoken card.

<p align="center">
  <img src="docs/assets/screenshot-onboarding.png" width="560" alt="Attaché first-run onboarding">
</p>

## The two settings that matter

- **Voice.** Grab a free macOS Premium voice (System Settings → Accessibility →
  Spoken Content → Manage Voices — try Ava or Zoe), or paste an ElevenLabs / xAI
  / OpenAI key for studio quality. Set it in **Settings → Voice & Captions**.
- **Personality.** The text brain that re-narrates your agents. Run a **local
  model free** with [Ollama](https://ollama.com), or plug in a cloud model. Then
  pick a persona in **Settings → Personalities** — or write your own.

## Bring your own brain and voice

Mix and match, per category:

|          | Local (private)                    | Cloud (frontier)              |
| -------- | ---------------------------------- | ----------------------------- |
| **Model** | Ollama, LM Studio (qwen, llama, glm) | xAI, Groq, Claude, Codex, any OpenAI-compatible |
| **Voice** | on-device macOS voices             | ElevenLabs, xAI, OpenAI       |

Run a local model with an on-device voice and **nothing ever leaves your Mac**.
Reach for the cloud when you want frontier quality on non-sensitive work. The
first time you pick a cloud provider, Attaché tells you exactly what gets sent.

## Shortcuts

| Key | Does |
| --- | --- |
| **⌘K** | Find and pin sessions |
| **⌘I** | Inbox |
| **⌘Y** | History |
| **⌘L** | Start or end a live conversation |
| **S / D / R** | Playback slower, faster, reset |
| **⌘/** | All shortcuts |

## Docs

[Quick start](docs/quick-start.md) ·
[The mindset](docs/mindset.md) ·
[Contributing personalities & themes](CONTRIBUTING.md)

## License

[Functional Source License 1.1](LICENSE.md). Use it freely for anything except
building a competing product; it converts to the MIT license two years after
each release. Builds are code-signed and notarized under Bryanlabs LLC's Apple
Developer ID.
