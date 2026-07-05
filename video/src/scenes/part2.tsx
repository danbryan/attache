import React from "react";
import { AbsoluteFill, Audio, Sequence, staticFile, useCurrentFrame, interpolate } from "remotion";
import { T, FPS } from "../theme";
import { Stage, Rise, Headline, BrandMark, Capsule, Karaoke, KeyCap } from "../components";
import { UPDATE_MEMO_LEAD, karaokeEndFrame } from "../timing";
import manifest from "../vo-manifest.json";
import samples from "../voice-samples.json";

/* 8 — voice memos + ⌘Y: press ⌘Y, pick a memo from the list, it plays (Adam, concise). */
const MEMOS = [
  { title: "Episode is now five clips", time: "just now", sel: true },
  { title: "Pull request opened for review", time: "12m", sel: false },
  { title: "Tests green across the board", time: "34m", sel: false },
];
const MEMO_LINE = "Your episode's cut into five clips. Captioned and queued to post.";
const memoDur = (samples as Record<string, { seconds: number }>).vs_concise.seconds;

export const Update: React.FC = () => {
  const frame = useCurrentFrame();
  const leadF = Math.round(UPDATE_MEMO_LEAD * FPS);
  const playing = frame >= leadF;
  const picked = frame > 150;
  const caret = Math.floor(frame / 15) % 2 === 0;
  return (
    <Stage>
      <Sequence from={leadF}><Audio src={staticFile("audio/vs_concise.wav")} /></Sequence>
      <AbsoluteFill style={{ alignItems: "center", justifyContent: "center", gap: 44 }}>
        <div style={{ display: "flex", gap: 20 }}>
          <KeyCap label="⌘" pressAt={105} wide />
          <KeyCap label="Y" pressAt={105} />
        </div>
        <Rise delay={20}>
          <div style={{ width: 960, borderRadius: 20, background: T.bgPanel, border: `1px solid ${T.stroke}`, overflow: "hidden", boxShadow: "0 40px 90px rgba(0,0,0,0.6)" }}>
            <div style={{ padding: "20px 28px", borderBottom: `1px solid ${T.stroke}`, color: T.dim, fontSize: 28 }}>
              Play a memo… <span style={{ color: T.text }}>{caret ? "▍" : " "}</span>
            </div>
            {MEMOS.map((m, i) => {
              const on = m.sel && picked;
              return (
                <div key={m.title} style={{ padding: "18px 28px", background: on ? T.goldSoft : "transparent", borderTop: i ? `1px solid ${T.stroke}` : "none" }}>
                  <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center" }}>
                    <div style={{ display: "flex", alignItems: "center", gap: 14 }}>
                      <div style={{ color: on ? T.gold : T.faint, fontSize: 24 }}>{on && playing ? "▶" : "♪"}</div>
                      <div style={{ color: T.text, fontSize: 27 }}>{m.title}</div>
                    </div>
                    <div style={{ color: T.faint, fontSize: 22 }}>{m.time}</div>
                  </div>
                  {m.sel && playing && (
                    <div style={{ display: "flex", alignItems: "center", gap: 16, marginTop: 14 }}>
                      <div style={{ color: T.gold, fontSize: 20, fontWeight: 600 }}>voice · Hope</div>
                      <div style={{ display: "flex", gap: 4, alignItems: "flex-end", height: 22 }}>
                        {Array.from({ length: 16 }).map((_, b) => (
                          <div key={b} style={{ width: 4, borderRadius: 3, background: T.gold, height: 6 + 15 * Math.abs(Math.sin(frame / 4 + b)) }} />
                        ))}
                      </div>
                    </div>
                  )}
                </div>
              );
            })}
          </div>
        </Rise>
        {playing && (
          <Karaoke text={MEMO_LINE} startFrame={leadF + 2} endFrame={leadF + karaokeEndFrame(memoDur, FPS)} fontSize={34} />
        )}
      </AbsoluteFill>
    </Stage>
  );
};

/* 8 — needs-you: banner + menu bar exclamation. */
export const NeedsYou: React.FC = () => {
  const frame = useCurrentFrame();
  const bannerIn = interpolate(frame, [55, 75], [420, 0], { extrapolateLeft: "clamp", extrapolateRight: "clamp" });
  return (
    <Stage>
      {/* menu bar strip */}
      <div style={{ position: "absolute", top: 0, width: "100%", height: 58, background: "rgba(20,20,26,0.9)", borderBottom: `1px solid ${T.stroke}`, display: "flex", alignItems: "center", justifyContent: "flex-end", padding: "0 40px", gap: 30, fontSize: 26, color: T.dim }}>
        <div style={{ color: frame > 60 ? T.gold : T.dim, fontWeight: 700 }}>
          {frame > 60 ? "A !" : "A"}
        </div>
        <div>Wed 9:41 AM</div>
      </div>
      {/* notification banner */}
      <div
        style={{
          position: "absolute", top: 84, right: 44, width: 560,
          transform: `translateX(${bannerIn}px)`,
          borderRadius: 20, background: "rgba(28,28,34,0.96)", border: `1px solid ${T.stroke}`,
          boxShadow: "0 30px 70px rgba(0,0,0,0.55)", padding: "24px 26px",
        }}
      >
        <div style={{ display: "flex", gap: 18, alignItems: "center" }}>
          <div style={{ width: 58, height: 58, borderRadius: 14, background: T.bgRaised, display: "flex", alignItems: "center", justifyContent: "center" }}>
            <BrandMark size={40} />
          </div>
          <div>
            <div style={{ color: T.text, fontSize: 27, fontWeight: 700 }}>Attaché · needs you</div>
            <div style={{ color: T.dim, fontSize: 24, marginTop: 4 }}>Claude is waiting on your answer</div>
          </div>
        </div>
        <div style={{ display: "flex", gap: 14, marginTop: 20 }}>
          {["Play", "Open Inbox", "Focus Session"].map((a) => (
            <div key={a} style={{ padding: "10px 20px", borderRadius: 12, background: "rgba(255,255,255,0.07)", color: T.text, fontSize: 22, fontWeight: 600 }}>{a}</div>
          ))}
        </div>
      </div>
      <AbsoluteFill style={{ alignItems: "center", justifyContent: "center", gap: 40 }}>
        <Headline size={70}>
          Quiet until it <span style={{ color: T.gold }}>matters</span>
        </Headline>
        <Rise delay={30}>
          <div style={{ color: T.dim, fontSize: 33, textAlign: "center", lineHeight: 1.5 }}>
            One notification, only when an agent is blocked on you.<br />
            Everything else just waits in the inbox.
          </div>
        </Rise>
      </AbsoluteFill>
    </Stage>
  );
};

/* 9 — inbox: voicemail cards. */
export const Inbox: React.FC = () => {
  const frame = useCurrentFrame();
  const cards = [
    { t: "Pull request ready for review", s: "2m ago", playing: true },
    { t: "Contract redline is back from counsel", s: "18m ago", playing: false },
    { t: "Q3 budget reconciled, one flag", s: "41m ago", playing: false },
  ];
  const progress = interpolate(frame, [30, 150], [0, 100], { extrapolateLeft: "clamp", extrapolateRight: "clamp" });
  return (
    <Stage>
      <AbsoluteFill style={{ alignItems: "center", justifyContent: "center", gap: 44 }}>
        <div style={{ display: "flex", alignItems: "center", gap: 26 }}>
          <Headline size={60}>Catch up like voicemail</Headline>
          <Rise delay={10}><Capsule active fontSize={26}>▶ Play all</Capsule></Rise>
        </div>
        <div style={{ display: "flex", flexDirection: "column", gap: 20, width: 980 }}>
          {cards.map((c, i) => (
            <Rise key={c.t} delay={14 + i * 16}>
              <div style={{ padding: "24px 30px", borderRadius: 18, background: c.playing ? T.goldSoft : T.bgPanel, border: `1px solid ${c.playing ? T.gold : T.stroke}` }}>
                <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center" }}>
                  <div style={{ color: T.text, fontSize: 30, fontWeight: 600 }}>{c.t}</div>
                  <div style={{ color: T.dim, fontSize: 23 }}>{c.s}</div>
                </div>
                {c.playing && (
                  <div style={{ marginTop: 16, height: 7, borderRadius: 4, background: "rgba(255,255,255,0.09)" }}>
                    <div style={{ width: `${progress}%`, height: "100%", borderRadius: 4, background: T.gold }} />
                  </div>
                )}
              </div>
            </Rise>
          ))}
        </div>
      </AbsoluteFill>
    </Stage>
  );
};


/* 14 — outro: end on the tagline. */
export const Outro: React.FC = () => {
  const frame = useCurrentFrame();
  const breathe = 0.9 + 0.08 * Math.sin(frame / 18);
  return (
    <Stage>
      <AbsoluteFill style={{ alignItems: "center", justifyContent: "center", gap: 54 }}>
        <div style={{ transform: `scale(${breathe})`, opacity: 0.92 }}>
          <BrandMark size={260} />
        </div>
        <Headline size={64} delay={10}>Fluent in agent. Speaks human.</Headline>
        <Rise delay={26}>
          <Capsule active fontSize={32}>github.com/danbryan/attache</Capsule>
        </Rise>
      </AbsoluteFill>
    </Stage>
  );
};
