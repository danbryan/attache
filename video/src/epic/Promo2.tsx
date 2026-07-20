import React from "react";
import { AbsoluteFill, Audio, Sequence, interpolate, staticFile } from "remotion";
import { T } from "../theme";
import { Shell } from "./components2";
import {
  SCENES2, sceneStarts, OVERLAP, f,
  hook, title, pin, inbox, ambient, live, twoway, personalities, brain, outro,
} from "./timing2";
import { Hook2, Title2, Pin2, Inbox2 } from "./scenes2a";
import { Ambient2, Live2, TwoWay2 } from "./scenes2b";
import { Personalities2, Brain2, Outro2 } from "./scenes2c";

const COMPS: Record<string, React.FC> = {
  hook: Hook2, title: Title2, pin: Pin2, inbox: Inbox2, ambient: Ambient2,
  live: Live2, twoway: TwoWay2, personalities: Personalities2, brain: Brain2, outro: Outro2,
};

// Narration clip per scene, at that scene's narrStart offset.
const NARRATION: Record<string, { clip: string; at: number }> = {
  hook: { clip: "n_hook", at: f(hook.narrStart) },
  title: { clip: "n_title", at: f(title.narrStart) },
  pin: { clip: "n_pin", at: f(pin.narrStart) },
  inbox: { clip: "n_inbox", at: f(inbox.narrStart) },
  ambient: { clip: "n_ambient", at: f(ambient.narrStart) },
  live: { clip: "n_live", at: f(live.narrStart) },
  personalities: { clip: "n_personalities", at: f(personalities.narrStart) },
  brain: { clip: "n_brain", at: f(brain.narrStart) },
  outro: { clip: "n_outro", at: f(outro.narrStart) },
};

const a2 = (name: string) => staticFile(`audio2/${name}.wav`);

const layout = sceneStarts();
export const PROMO2_FRAMES = layout.total;

export const Promo2: React.FC = () => {
  const { starts, frames } = layout;
  const startOf = (key: string) => starts[SCENES2.findIndex((s) => s.key === key)];
  const pinStart = startOf("pin");
  const inboxStart = startOf("inbox");
  const liveStart = startOf("live");
  const twowayStart = startOf("twoway");
  const persStart = startOf("personalities");
  const brainStart = startOf("brain");

  return (
    <AbsoluteFill style={{ backgroundColor: T.bg }}>
      {/* ---- scenes, crossfaded ---- */}
      {SCENES2.map((s, i) => {
        const Comp = COMPS[s.key];
        return (
          <Sequence key={s.key} from={starts[i]} durationInFrames={frames[i]}>
            <Shell duration={frames[i]} edge={OVERLAP}>
              <Comp />
            </Shell>
          </Sequence>
        );
      })}

      {/* ---- narration ---- */}
      {SCENES2.map((s, i) => {
        const n = NARRATION[s.key];
        if (!n) return null;
        return (
          <Sequence key={`n-${s.key}`} from={starts[i] + n.at}>
            <Audio src={a2(n.clip)} />
          </Sequence>
        );
      })}
      {/* two-way narration is split around the confirm beat */}
      <Sequence from={twowayStart + f(twoway.aStart)}>
        <Audio src={a2("n_two_a")} />
      </Sequence>
      <Sequence from={twowayStart + f(twoway.bStart)}>
        <Audio src={a2("n_two_b")} />
      </Sequence>

      {/* ---- in-app voices ---- */}
      <Sequence from={inboxStart + f(inbox.memoStart)}>
        <Audio src={a2("va_memo")} />
      </Sequence>
      <Sequence from={liveStart + f(live.speakAt)}>
        <Audio src={a2("va_live")} />
      </Sequence>
      <Sequence from={twowayStart + f(twoway.replySpeakAt)}>
        <Audio src={a2("va_reply")} />
      </Sequence>
      <Sequence from={persStart + f(personalities.editorSpeakAt)}>
        <Audio src={a2("vs_editor")} />
      </Sequence>
      <Sequence from={persStart + f(personalities.cowboySpeakAt)}>
        <Audio src={a2("vs_cowboy")} />
      </Sequence>

      {/* ---- sound design ---- */}
      {starts.slice(1).map((from, i) => (
        <Sequence key={`whoosh-${i}`} from={from - 4}>
          <Audio src={a2("sfx_whoosh")} volume={0.38} />
        </Sequence>
      ))}
      <Sequence from={startOf("title") + f(title.barsAt)}>
        <Audio src={a2("sfx_hit")} volume={0.8} />
      </Sequence>
      {inbox.cardsAt.map((at, i) => (
        <Sequence key={`pop-${i}`} from={inboxStart + f(at)}>
          <Audio src={a2("sfx_pop")} volume={0.5} />
        </Sequence>
      ))}
      <Sequence from={pinStart + f(pin.pinAt)}>
        <Audio src={a2("sfx_pop")} volume={0.5} />
      </Sequence>
      <Sequence from={twowayStart + f(twoway.chipFlipAt)}>
        <Audio src={a2("sfx_pop")} volume={0.5} />
      </Sequence>
      <Sequence from={twowayStart + f(twoway.confirmAt)}>
        <Audio src={a2("sfx_pop")} volume={0.5} />
      </Sequence>
      <Sequence from={twowayStart + f(twoway.deliveredAt)}>
        <Audio src={a2("sfx_flutter")} volume={0.4} />
      </Sequence>
      <Sequence from={brainStart + f(brain.toggleAt)}>
        <Audio src={a2("sfx_pop")} volume={0.5} />
      </Sequence>
      <Sequence from={brainStart + f(brain.fallbackAt)}>
        <Audio src={a2("sfx_pop")} volume={0.5} />
      </Sequence>

      {/* ---- music bed ---- */}
      <Audio
        src={a2("music_bed")}
        loop
        volume={(frame) =>
          interpolate(frame, [0, 40, PROMO2_FRAMES - 80, PROMO2_FRAMES - 8], [0, 0.4, 0.4, 0], {
            extrapolateLeft: "clamp",
            extrapolateRight: "clamp",
          })
        }
      />
    </AbsoluteFill>
  );
};
