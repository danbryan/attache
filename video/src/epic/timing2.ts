import m from "./manifest2.json";
import { FPS } from "../theme";

// Every beat in Promo2 is derived from the measured audio durations in
// manifest2.json (written back by generate-vo2.sh), same contract as the
// original video's timing.ts: regenerate audio, and the choreography follows.

export const nsec = (k: keyof typeof m.narration): number => m.narration[k].seconds;
export const ssec = (k: keyof typeof m.samples): number => m.samples[k].seconds;
export const ntext = (k: keyof typeof m.narration): string => m.narration[k].text;
export const stext = (k: keyof typeof m.samples): string => m.samples[k].text;

export const f = (sec: number): number => Math.round(sec * FPS);

/** Frames of scene-to-scene crossfade overlap. */
export const OVERLAP = 14;

// ---- 1: hook — one agent, then a wall of them --------------------------
export const hook = (() => {
  const narrStart = 0.5;
  // "And it's not the only one" — the wall of mini sessions floods in.
  const wallAt = narrStart + 3.6;
  const narrEnd = narrStart + nsec("n_hook");
  // Two-stage reveal around the scripted dramatic pause: "Your agents are
  // talking." lands first, then after the 1.2s break the payoff line —
  // Attaché's first mention — lands on its own beat.
  const lineAt = narrEnd - 4.9;
  const line2At = narrEnd - 1.85;
  const collapseAt = narrEnd + 0.4;
  const len = collapseAt + 1.2;
  return { narrStart, wallAt, lineAt, line2At, collapseAt, len };
})();

// ---- 2: title -----------------------------------------------------------
export const title = (() => {
  const barsAt = 0.15;
  const nameAt = 0.45;
  const narrStart = 1.0;
  const tagAt = narrStart + nsec("n_title") * 0.55;
  const len = Math.max(6.4, narrStart + nsec("n_title") + 2.4);
  return { barsAt, nameAt, narrStart, tagAt, len };
})();

// ---- 3: pin the sessions you care about ---------------------------------
export const pin = (() => {
  const narrStart = 0.3;
  const keysAt = 0.5;
  const paletteAt = 1.1;
  const pinAt = 3.4;
  const len = narrStart + nsec("n_pin") + 1.3;
  return { narrStart, keysAt, paletteAt, pinAt, len };
})();

// ---- 4: voicemail inbox + media controls + recap ------------------------
export const inbox = (() => {
  const narrStart = 0.35;
  const cardsAt = [0.9, 1.35, 1.8];
  const narrEnd = narrStart + nsec("n_inbox");
  // One voice at a time: the memo only plays after the narration finishes.
  const memoStart = narrEnd + 0.45;
  const speedAt = memoStart + 1.6;   // 1.0x -> 1.5x capsule flips
  const scrubAt = memoStart + 3.0;   // progress jumps forward
  const recapAt = narrEnd - 1.8;     // "…hit Recap" — the button glows
  const len = memoStart + ssec("va_memo") + 1.2;
  return { narrStart, cardsAt, memoStart, speedAt, scrubAt, recapAt, len };
})();

// ---- 5: ambient presence — the activity heat map -------------------------
export const ambient = (() => {
  const narrStart = 0.4;
  const narrEnd = narrStart + nsec("n_ambient");
  // After the narration, a short music-carried showcase of the character
  // picker (pets can be changed).
  const charactersAt = narrEnd + 0.5;
  const len = charactersAt + 4.2;
  return { narrStart, narrEnd, charactersAt, len };
})();

// ---- 6: live call --------------------------------------------------------
export const live = (() => {
  const narrStart = 0.35;
  const composerAt = 0.7;
  const listenAt = 1.3;
  const thinkAt = listenAt + 2.4;
  const prepAt = thinkAt + 2.2;
  const narrEnd = narrStart + nsec("n_live");
  const speakAt = Math.max(prepAt + 1.3, narrEnd + 0.35);
  const len = speakAt + ssec("va_live") + 1.1;
  return { narrStart, composerAt, listenAt, thinkAt, prepAt, speakAt, len };
})();

// ---- 7: two-way send (the centerpiece) -----------------------------------
export const twoway = (() => {
  const aStart = 0.25;
  const chipFlipAt = 0.9;
  const typedAt = 1.7;
  const typedDur = 1.9;
  const confirmAt = aStart + nsec("n_two_a") + 0.35;
  const sendPressAt = confirmAt + 1.15;
  const bStart = sendPressAt + 0.55;
  const queuedAt = sendPressAt + 0.4;
  const quietAt = queuedAt + 3.4;
  const deliverTypeAt = quietAt + 0.5;
  const deliveredAt = deliverTypeAt + 1.5;
  const waitingAt = deliveredAt + 2.4;
  const bEnd = bStart + nsec("n_two_b");
  const replyPrintAt = Math.max(waitingAt + 3.0, bEnd - 1.2);
  const replyCardAt = replyPrintAt + 1.0;
  const replySpeakAt = Math.max(replyCardAt + 0.6, bEnd + 0.3);
  const len = replySpeakAt + ssec("va_reply") + 1.3;
  return {
    aStart, chipFlipAt, typedAt, typedDur, confirmAt, sendPressAt,
    bStart, queuedAt, quietAt, deliverTypeAt, deliveredAt, waitingAt,
    replyPrintAt, replyCardAt, replySpeakAt, len,
  };
})();

// ---- 8: character studio, a game-style loadout and live audition -----------
export const personalities = (() => {
  const narrStart = 0.3;
  const presetsAt = 0.8;
  const editorTypeAt = narrStart + nsec("n_personalities") - 3.0;
  const typeDur = 1.4;
  const editorSpeakAt = Math.max(editorTypeAt + typeDur + 0.4, narrStart + nsec("n_personalities") + 0.3);
  const cowboyTypeAt = editorSpeakAt + ssec("vs_editor") + 0.6;
  const cowboySpeakAt = cowboyTypeAt + typeDur + 0.4;
  const len = cowboySpeakAt + ssec("vs_cowboy") + 1.0;
  return { narrStart, presetsAt, editorTypeAt, typeDur, editorSpeakAt, cowboyTypeAt, cowboySpeakAt, len };
})();

// ---- 9: its own brain — local or frontier, with fallback -------------------
export const brain = (() => {
  const narrStart = 0.35;
  const watchAt = 0.6;
  const brainAt = narrStart + 3.2;   // "…thinks with its own model"
  // The toggle must flip AS the narration says "frontier", not sentences
  // earlier. "frontier" is word 25 of 37 in n_brain, so anchor the flip to
  // that fraction of the measured clip (slightly early so the highlight
  // lands mid-word).
  const toggleAt = narrStart + nsec("n_brain") * 0.64;
  const fallbackAt = narrStart + nsec("n_brain") * 0.80; // "…runs dry" banner
  const len = narrStart + nsec("n_brain") + 1.7;
  return { narrStart, watchAt, brainAt, toggleAt, fallbackAt, len };
})();

// ---- 10: outro ------------------------------------------------------------
export const outro = (() => {
  const narrStart = 0.7;
  const len = narrStart + nsec("n_outro") + 3.2;
  return { narrStart, len };
})();

// ---- launch cut: two extra music-carried beats (no narration) ------------
// Beat A — the agent lineup: "works with the agents you already run", four
// name cards, then the two-way payoff line. Music-carried, on-screen copy only.
export const lineup = (() => {
  const headlineAt = 0.35;
  const cardsAt = 1.15;   // first card in; the rest stagger after
  const line2At = 4.7;    // "Watch them. Reply to them."
  const len = 7.0;
  return { headlineAt, cardsAt, line2At, len };
})();

// Beat B — the bundled voice: "a premium voice, included", runs on your Mac,
// and Attaché speaks the Azelma preview line with caption-synced karaoke.
export const voiceBeat = (() => {
  const headlineAt = 0.35;
  const sublineAt = 1.0;
  const speakAt = 2.4;    // Azelma preview starts
  const len = speakAt + ssec("va_azelma") + 2.9;
  return { headlineAt, sublineAt, speakAt, len };
})();

// ---- launch cut: two-way and brain re-derived from the recut narration -----
// The launch cut replaces the two-way narration (n_two_a_launch / n_two_b_launch)
// and the watched-harness narration (n_brain_launch). Both beats derive their
// choreography the same way the baseline objects do, but from the recut clip
// lengths, so the baseline `twoway` / `brain` (and Promo2) stay untouched.
export const twowayLaunch = (() => {
  const aStart = 0.25;
  const chipFlipAt = 0.9;
  const typedAt = 1.7;
  const typedDur = 1.9;
  const confirmAt = aStart + nsec("n_two_a_launch") + 0.35;
  const sendPressAt = confirmAt + 1.15;
  const bStart = sendPressAt + 0.55;
  const queuedAt = sendPressAt + 0.4;
  const quietAt = queuedAt + 3.4;
  const deliverTypeAt = quietAt + 0.5;
  const deliveredAt = deliverTypeAt + 1.5;
  const waitingAt = deliveredAt + 2.4;
  const bEnd = bStart + nsec("n_two_b_launch");
  const replyPrintAt = Math.max(waitingAt + 3.0, bEnd - 1.2);
  const replyCardAt = replyPrintAt + 1.0;
  const replySpeakAt = Math.max(replyCardAt + 0.6, bEnd + 0.3);
  const len = replySpeakAt + ssec("va_reply") + 1.3;
  return {
    aStart, chipFlipAt, typedAt, typedDur, confirmAt, sendPressAt,
    bStart, queuedAt, quietAt, deliverTypeAt, deliveredAt, waitingAt,
    replyPrintAt, replyCardAt, replySpeakAt, len,
  };
})();

export const brainLaunch = (() => {
  const narrStart = 0.35;
  const watchAt = 0.6;
  const brainAt = narrStart + 3.2;
  const toggleAt = narrStart + nsec("n_brain_launch") * 0.64;
  const fallbackAt = narrStart + nsec("n_brain_launch") * 0.80;
  const len = narrStart + nsec("n_brain_launch") + 1.7;
  return { narrStart, watchAt, brainAt, toggleAt, fallbackAt, len };
})();

// The launch ambient beat drops the "Pick your Attaché" picker tail (beat D),
// ending just after the "it speaks up" caption completes.
export const ambientLaunchLen = ambient.charactersAt + 0.4;

export type SceneSpec = { key: string; lenSec: number };
// Personalities ("it talks your way") runs BEFORE the conversational block
// (live + two-way), per direction: establish how it speaks, then talk to it.
export const SCENES2: SceneSpec[] = [
  { key: "hook", lenSec: hook.len },
  { key: "title", lenSec: title.len },
  { key: "pin", lenSec: pin.len },
  { key: "inbox", lenSec: inbox.len },
  { key: "ambient", lenSec: ambient.len },
  { key: "personalities", lenSec: personalities.len },
  { key: "live", lenSec: live.len },
  { key: "twoway", lenSec: twoway.len },
  { key: "brain", lenSec: brain.len },
  { key: "outro", lenSec: outro.len },
];

// The launch cut: the baseline sequence with the lineup beat after the hook
// (which establishes the wall of watched agents). The "Pick your Attaché"
// picker tail and the bundled-voice beat are cut; the two-way and watched-
// harness beats run on their recut narration lengths.
export const SCENES2_LAUNCH: SceneSpec[] = [
  { key: "hook", lenSec: hook.len },
  { key: "lineup", lenSec: lineup.len },
  { key: "title", lenSec: title.len },
  { key: "pin", lenSec: pin.len },
  { key: "inbox", lenSec: inbox.len },
  { key: "ambient", lenSec: ambientLaunchLen },
  { key: "personalities", lenSec: personalities.len },
  { key: "live", lenSec: live.len },
  { key: "twoway", lenSec: twowayLaunch.len },
  { key: "brain", lenSec: brainLaunch.len },
  { key: "outro", lenSec: outro.len },
];

/** Start frame of each scene, with OVERLAP frames of crossfade between them. */
export function layoutScenes(scenes: SceneSpec[]): { starts: number[]; frames: number[]; total: number } {
  const frames = scenes.map((s) => f(s.lenSec));
  const starts: number[] = [];
  let cursor = 0;
  for (let i = 0; i < frames.length; i++) {
    starts.push(cursor);
    cursor += frames[i] - OVERLAP;
  }
  return { starts, frames, total: cursor + OVERLAP };
}

export function sceneStarts(): { starts: number[]; frames: number[]; total: number } {
  return layoutScenes(SCENES2);
}

/** Karaoke should span only the actual speech, not trailing silence. */
export function karaokeEnd(seconds: number, tail = 0.35): number {
  return Math.round((seconds - tail) * FPS);
}
