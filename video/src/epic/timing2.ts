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
  // "Your agents are talking…" — dim the wall, land the line.
  const lineAt = narrStart + nsec("n_hook") - 4.4;
  const collapseAt = narrStart + nsec("n_hook") + 0.3;
  const len = collapseAt + 1.2;
  return { narrStart, wallAt, lineAt, collapseAt, len };
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
  // Playback starts early so the controls have something real to act on.
  const memoStart = 4.6;
  const speedAt = memoStart + 2.2;   // 1.0x -> 1.5x capsule flips
  const scrubAt = memoStart + 3.6;   // progress jumps forward
  const narrEnd = narrStart + nsec("n_inbox");
  const recapAt = narrEnd - 1.8;     // "…hit Recap" — the button glows
  const len = Math.max(narrEnd, memoStart + ssec("va_memo")) + 1.2;
  return { narrStart, cardsAt, memoStart, speedAt, scrubAt, recapAt, len };
})();

// ---- 5: ambient presence — the activity heat map -------------------------
export const ambient = (() => {
  const narrStart = 0.4;
  const len = narrStart + nsec("n_ambient") + 1.4;
  return { narrStart, len };
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

// ---- 8: personalities — presets, then write your own ----------------------
export const personalities = (() => {
  const narrStart = 0.3;
  const presetsAt = 0.8;
  const editorTypeAt = narrStart + nsec("n_personalities") - 3.0;
  const typeDur = 1.4;
  const editorSpeakAt = Math.max(editorTypeAt + typeDur + 0.4, narrStart + nsec("n_personalities") + 0.3);
  const hypeTypeAt = editorSpeakAt + ssec("vs_editor") + 0.6;
  const hypeSpeakAt = hypeTypeAt + typeDur + 0.4;
  const len = hypeSpeakAt + ssec("vs_hype") + 1.0;
  return { narrStart, presetsAt, editorTypeAt, typeDur, editorSpeakAt, hypeTypeAt, hypeSpeakAt, len };
})();

// ---- 9: its own brain — local or frontier, with fallback -------------------
export const brain = (() => {
  const narrStart = 0.35;
  const watchAt = 0.6;
  const brainAt = narrStart + 3.2;   // "…thinks with its own model"
  const toggleAt = narrStart + 5.2;  // local -> frontier slide
  const fallbackAt = narrStart + nsec("n_brain") - 4.2; // "…runs dry" banner
  const len = narrStart + nsec("n_brain") + 1.7;
  return { narrStart, watchAt, brainAt, toggleAt, fallbackAt, len };
})();

// ---- 10: outro ------------------------------------------------------------
export const outro = (() => {
  const narrStart = 0.7;
  const len = narrStart + nsec("n_outro") + 3.2;
  return { narrStart, len };
})();

export type SceneSpec = { key: string; lenSec: number };
export const SCENES2: SceneSpec[] = [
  { key: "hook", lenSec: hook.len },
  { key: "title", lenSec: title.len },
  { key: "pin", lenSec: pin.len },
  { key: "inbox", lenSec: inbox.len },
  { key: "ambient", lenSec: ambient.len },
  { key: "live", lenSec: live.len },
  { key: "twoway", lenSec: twoway.len },
  { key: "personalities", lenSec: personalities.len },
  { key: "brain", lenSec: brain.len },
  { key: "outro", lenSec: outro.len },
];

/** Start frame of each scene, with OVERLAP frames of crossfade between them. */
export function sceneStarts(): { starts: number[]; frames: number[]; total: number } {
  const frames = SCENES2.map((s) => f(s.lenSec));
  const starts: number[] = [];
  let cursor = 0;
  for (let i = 0; i < frames.length; i++) {
    starts.push(cursor);
    cursor += frames[i] - OVERLAP;
  }
  return { starts, frames, total: cursor + OVERLAP };
}

/** Karaoke should span only the actual speech, not trailing silence. */
export function karaokeEnd(seconds: number, tail = 0.35): number {
  return Math.round((seconds - tail) * FPS);
}
