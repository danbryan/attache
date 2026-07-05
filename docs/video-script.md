# YouTube tutorial script

Target: 3 to 4 minutes. One take per scene, screen recording plus voiceover.
Record at 1x, keep the app in the dark default theme, volume up so the spoken
recaps are audible in the video.

| # | Time | On screen | Narration |
| --- | --- | --- | --- |
| 1 | 0:00 | Terminal running a Claude Code task, camera slowly pushes in | "This agent is going to work for the next ten minutes. The question is: what are you going to do, sit here and watch it?" |
| 2 | 0:15 | Cut to Attaché idle window (monochrome A), then a card arrives and speaks | "This is Attaché. It watches the agents working on your Mac, and when one finishes something, it tells you. Out loud." (let the recap play a few seconds, captions highlighting) |
| 3 | 0:40 | GitHub Releases page, drag Attache.app to Applications, first launch | "Install is one download. It's signed and notarized, everything runs locally, and there's no account." |
| 4 | 0:55 | Onboarding: voice pick, personality pick, enable Claude Code source | "Onboarding takes two minutes: pick a voice, pick a personality, and choose which agents it may watch. Nothing is read until you say so." |
| 5 | 1:20 | Press ⌘K, type a session name, pin it | "Command-K, pin the session you care about. That's the whole setup. Attaché only ever speaks about sessions you pin." |
| 6 | 1:35 | Agent finishes a turn; recap speaks with karaoke captions; visualizer reacting | "From now on every completed turn arrives like this: a short spoken brief, word-synced captions, and a card filed in the inbox." |
| 7 | 1:55 | Playback: press S, D, badge shows 1.2x, captions stay locked | "Too slow? D speeds it up, S slows it down, R resets. The captions stay in sync at any speed." |
| 8 | 2:10 | Step away b-roll; needs-you notification fires; menu bar shows alert; click it | "Here's the part that matters: walk away. When an agent actually needs you, a permission prompt, a question, Attaché interrupts you once, through a real macOS notification that respects Do Not Disturb. Everything else just waits in the inbox." |
| 9 | 2:40 | ⌘I inbox, play-all digest for a session, skip through cards | "Come back whenever, Command-I, and catch up like voicemail. Play all, skip, replay." |
| 10 | 3:00 | Settings → Personalities, switch persona; replay same card sounding different; flash a Korean recap with Korean captions | "And you decide how it talks. Tone, attitude, detail, even the language. Same update, completely different delivery." |
| 11 | 3:25 | Idle window again, menu bar icon, repo page | "Attaché is free and open source, link below. Stop watching terminals. Let them call you." |

## Recording checklist

- Fresh profile for the install scenes so onboarding actually shows.
- Have `scripts/send-event.sh` ready to trigger cards on cue.
- For scene 8, a Claude Code `AskUserQuestion` or permission prompt triggers
  the real needs-you flow.
- Trim silences; the recaps themselves set the pace.
- Title suggestion: "Your AI agents, out loud. Attaché for macOS in 3 minutes".
