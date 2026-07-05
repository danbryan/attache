import React from "react";
import { AbsoluteFill, Audio, Composition, Sequence, staticFile } from "remotion";
import { FPS } from "./theme";
import manifest from "./vo-manifest.json";
import { personalitiesTimeline, updateTotalSec } from "./timing";
import { Intro, Install, Onboard, Pin } from "./scenes/part1";
import { Update, NeedsYou, Outro } from "./scenes/part2";
import { LocalFrontier, Personalities, Live } from "./scenes/part3";
import { ColdOpen, ColdCard, COLD_OPEN_FRAMES, COLD_CARD_FRAMES } from "./scenes/coldopen";

type SceneDef = {
  key: string;
  Comp: React.FC;
  pad: number;
  minSec?: number;
  ownAudio?: boolean; // the scene renders its own audio; Root attaches none
  fixedFrames?: number; // explicit duration, bypasses the narration manifest
  audioKey?: keyof typeof manifest;
};

const SCENES: SceneDef[] = [
  { key: "coldcard", Comp: ColdCard, pad: 0, ownAudio: true, fixedFrames: COLD_CARD_FRAMES },
  { key: "intro", Comp: Intro, pad: 0.9 },
  { key: "install", Comp: Install, pad: 2.0 },
  { key: "onboard", Comp: Onboard, pad: 1.0 },
  { key: "byo", Comp: LocalFrontier, pad: 1.0 },
  { key: "pin", Comp: Pin, pad: 0.9 },
  { key: "update", Comp: Update, pad: 0.4, minSec: updateTotalSec() },
  { key: "personalities", Comp: Personalities, pad: 0.4, minSec: personalitiesTimeline().totalSec },
  { key: "needs", Comp: NeedsYou, pad: 1.0 },
  { key: "live", Comp: Live, pad: 1.0 },
  { key: "outro", Comp: Outro, pad: 1.6 },
];

function sceneFrames(s: SceneDef): number {
  if (s.fixedFrames) return s.fixedFrames;
  const narration = manifest[(s.audioKey ?? s.key) as keyof typeof manifest].seconds + s.pad;
  return Math.ceil(Math.max(narration, s.minSec ?? 0) * FPS);
}

const TOTAL = SCENES.reduce((sum, s) => sum + sceneFrames(s), 0);

const Tutorial: React.FC = () => {
  let cursor = 0;
  return (
    <AbsoluteFill style={{ backgroundColor: "#0A0A0D" }}>
      {SCENES.map((s) => {
        const from = cursor;
        const durationInFrames = sceneFrames(s);
        cursor += durationInFrames;
        const { key, Comp, ownAudio, audioKey } = s;
        return (
          <Sequence key={key} from={from} durationInFrames={durationInFrames}>
            <Comp />
            {!ownAudio && <Audio src={staticFile(`audio/${audioKey ?? key}.wav`)} />}
          </Sequence>
        );
      })}
    </AbsoluteFill>
  );
};

export const RemotionRoot: React.FC = () => (
  <>
    <Composition id="Tutorial" component={Tutorial} durationInFrames={TOTAL} fps={FPS} width={1920} height={1080} />
    <Composition id="ColdOpen" component={ColdOpen} durationInFrames={COLD_OPEN_FRAMES} fps={FPS} width={1920} height={1080} />
  </>
);
