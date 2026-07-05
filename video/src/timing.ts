import samples from "./voice-samples.json";
import vo from "./vo-manifest.json";

const sdur = (name: string): number => (samples as Record<string, { seconds: number }>)[name].seconds;

// Personalities: a quick nod to the presets, then the hero — write your own
// personality and Attaché talks like that. Each custom prompt types in, then its
// voice delivers the same update in that style. Root (scene length) and the scene
// (typewriter + speak timing) both read this layout.
export const PRESETS = ["Explainer", "Big Picture", "Inquisitive"] as const;

export const CUSTOM_SEQ = [
  { key: "editor", prompt: "a sharp editor with strong opinions", emoji: "🎬", voice: "Jessica", sample: "vs_editor", tint: "#0A84FF" },
  { key: "hype", prompt: "an over-caffeinated hype coach", emoji: "🔥", voice: "Titan", sample: "vs_hype", tint: "#0A84FF" },
] as const;

export type CustomItem = {
  key: string; prompt: string; emoji: string; voice: string; sample: string; tint: string; index: number;
  typeStart: number; sampleStart: number; sampleDur: number; activeStart: number; activeEnd: number;
};

export function personalitiesTimeline(): { items: CustomItem[]; totalSec: number } {
  const lead = (vo as Record<string, { seconds: number }>).personalities.seconds + 0.4;
  const typeDur = 1.1, gap = 0.25, betweenGap = 0.7, tail = 0.9;
  let t = lead;
  const items: CustomItem[] = CUSTOM_SEQ.map((c, index) => {
    const typeStart = t;
    const sampleStart = typeStart + typeDur + gap;
    const sampleDur = sdur(c.sample);
    const activeEnd = sampleStart + sampleDur;
    t = activeEnd + betweenGap;
    return { ...c, index, typeStart, sampleStart, sampleDur, activeStart: typeStart, activeEnd };
  });
  return { items, totalSec: t - betweenGap + tail };
}

// Update: the narration explains voice memos + ⌘Y, then the picked memo plays
// (Adam, concise) once the narration lands.
export const UPDATE_MEMO_LEAD = 7.5;
export function updateTotalSec(): number {
  return UPDATE_MEMO_LEAD + sdur("vs_concise") + 1.0;
}

// Karaoke should span only the actual speech, not the whole clip (clips carry a
// little trailing silence). Ties the caption pace to the voiceover length.
export function karaokeEndFrame(seconds: number, fps: number, tail = 0.35): number {
  return Math.round((seconds - tail) * fps);
}
