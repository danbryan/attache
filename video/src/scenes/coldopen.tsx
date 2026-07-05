import React from "react";
import { AbsoluteFill, Audio, Sequence, staticFile, useCurrentFrame, interpolate, spring, useVideoConfig } from "remotion";
import { T, FPS } from "../theme";
import { Stage, BrandMark, Karaoke } from "../components";
import { karaokeEndFrame } from "../timing";
import { Intro } from "./part1";
import cold from "../cold-open.json";

const C1 = Math.round(cold.creator.seconds * FPS);

/** The creator card, speaking (Jessa). Shared by the demo and the promo. */
const CreatorCard: React.FC<{ fade: number }> = ({ fade }) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const cardIn = spring({ frame, fps, config: { damping: 200 } });
  return (
    <AbsoluteFill style={{ opacity: fade }}>
      <Stage>
        <AbsoluteFill style={{ alignItems: "center", justifyContent: "center" }}>
          <div
            style={{
              width: 1180, borderRadius: 26, background: "rgba(20,20,26,0.72)", border: `1px solid ${T.stroke}`,
              boxShadow: "0 50px 110px rgba(0,0,0,0.6)", padding: "36px 48px 46px",
              transform: `translateY(${(1 - cardIn) * 30}px)`, opacity: cardIn,
              display: "flex", flexDirection: "column", alignItems: "center", gap: 24,
            }}
          >
            <div style={{ alignSelf: "stretch", display: "flex", alignItems: "center", gap: 13 }}>
              <div style={{ width: 12, height: 12, borderRadius: 8, background: T.gold }} />
              <div style={{ color: T.text, fontSize: 26, fontWeight: 700 }}>New upload</div>
              <div style={{ color: T.dim, fontSize: 22 }}>· just now</div>
            </div>
            <BrandMark size={140} animate barColor={(i) => `rgba(10,132,255,${0.4 + 0.05 * i})`} />
            <Karaoke text={cold.creator.text} startFrame={3} endFrame={karaokeEndFrame(cold.creator.seconds, FPS, 0.3)} fontSize={38} />
          </div>
        </AbsoluteFill>
      </Stage>
    </AbsoluteFill>
  );
};

/** Integrated promo opener: the card speaks, then fades so the Intro follows. */
export const COLD_CARD_FRAMES = C1 + 14;
export const ColdCard: React.FC = () => {
  const frame = useCurrentFrame();
  const fade = interpolate(frame, [0, 10, C1 - 2, C1 + 12], [0, 1, 1, 0], { extrapolateLeft: "clamp", extrapolateRight: "clamp" });
  return (
    <AbsoluteFill style={{ backgroundColor: T.bg }}>
      <Audio src={staticFile("audio/cold_creator.wav")} />
      <CreatorCard fade={fade} />
    </AbsoluteFill>
  );
};

/* Standalone demo: card hands off into the tutorial's title beat. */
const XFADE = 18;
const INTRO_START = C1 - XFADE;
const INTRO_LEN = 168;
export const COLD_OPEN_FRAMES = INTRO_START + INTRO_LEN;

export const ColdOpen: React.FC = () => {
  const frame = useCurrentFrame();
  const cardFade = interpolate(frame, [INTRO_START, C1 + 2], [1, 0], { extrapolateLeft: "clamp", extrapolateRight: "clamp" });
  const introFade = interpolate(frame, [INTRO_START, INTRO_START + XFADE], [0, 1], { extrapolateLeft: "clamp", extrapolateRight: "clamp" });
  return (
    <AbsoluteFill style={{ backgroundColor: T.bg }}>
      <Audio src={staticFile("audio/cold_creator.wav")} />
      {frame < C1 + 4 && <CreatorCard fade={cardFade} />}
      {frame >= INTRO_START && (
        <AbsoluteFill style={{ opacity: introFade }}>
          <Sequence from={INTRO_START} durationInFrames={INTRO_LEN}>
            <Intro />
            <Audio src={staticFile("audio/intro.wav")} />
          </Sequence>
        </AbsoluteFill>
      )}
    </AbsoluteFill>
  );
};
