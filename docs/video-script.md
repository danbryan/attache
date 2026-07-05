# Promo video script

The video is produced and live: about 1 minute 45 seconds, screen recording plus
voiceover. Tagline: **Fluent in agent. Speaks human.** Record at 1x in the default
macOS theme, volume up so the spoken updates are audible.

| # | Time | On screen | Narration |
| --- | --- | --- | --- |
| 1 | 0:00 | Terminal running a Claude Code task, slow push-in | "This agent is going to work for the next ten minutes. Are you going to sit here and watch it?" |
| 2 | 0:12 | Cut to the idle Attaché window; a card arrives and speaks, captions highlighting word by word | "This is Attaché. It watches the AI agents working on your Mac, and when one finishes something, it tells you. Out loud, in a voice you pick." |
| 3 | 0:30 | GitHub Releases page, drag Attaché to Applications, first launch opens clean | "One download, signed and notarized. No account. Everything runs locally." |
| 4 | 0:42 | Onboarding: pick a voice, pick a personality, pick a model, choose which agents it may watch | "Onboarding is two minutes: a voice, a personality, a model, and which agents it may watch. It stays quiet until you say otherwise." |
| 5 | 0:56 | Press Command-K, filter to a session, pin it | "Command-K, pin the session you care about. Attaché only ever speaks about sessions you pin." |
| 6 | 1:04 | An agent finishes a turn; the update speaks with word-synced captions; visualizer reacting; press S then D, speed badge changes, captions stay locked | "Every completed turn arrives like this. A short spoken update, synced captions, filed like voicemail. Too slow? Speed it up. The captions stay in sync." |
| 7 | 1:20 | Step-away b-roll; a needs-you notification fires; menu bar shows the alert; click it | "Walk away. When an agent actually needs you, Attaché interrupts once, through a real macOS notification that respects Do Not Disturb. Everything else waits." |
| 8 | 1:34 | Command-I inbox; one-shot Recap plays a clustered digest | "Come back whenever. Command-I, and catch up like voicemail, or hit Recap for one spoken summary of everything you missed." |
| 9 | 1:48 | Command-L: speak a new instruction, confirm the read-back, it delivers to the running session | "Or go live. Talk back by voice and push new direction straight to the agents, on your say-so." |
| 10 | 2:02 | Settings, Personalities: switch persona and theme; replay the same update sounding different | "You decide how it talks. Tone, attitude, detail, even the language. Same update, completely different delivery." |
| 11 | 2:14 | Idle window, menu bar icon, repo page, tagline card | "Attaché. Fluent in agent. Speaks human. Free and open source, link below. Stop watching terminals. Let them call you." |

## Recording checklist

- Fresh profile for the install and onboarding scenes so first-run actually
  shows.
- Have `scripts/send-event.sh` ready to trigger updates on cue (it needs the
  per-launch token at `~/Library/Application Support/Attache/event-token`).
- For scene 7, a Claude Code permission prompt or question triggers the real
  needs-you flow.
- For scene 9, enable two-way on the demo session first, then speak the
  instruction so the confirm-and-deliver path is genuine.
- Trim silences; the spoken updates set the pace.
- Title suggestion: "Your AI agents, out loud. Attaché for macOS."
