import React from "react";
import { AbsoluteFill, interpolate, spring, useCurrentFrame, useVideoConfig } from "remotion";
import { T, FPS } from "../theme";
import { Stage } from "../components";
import {
  Aurora, Particles, LightSweep, Camera, RingPulse, Terminal, TermLine, AppWindow,
  StatusRow, Composer, WordSweep, WaveBars, FloatingVerbs, Mark2, typed as typeSlice,
} from "./components2";
import { ambient, live, twoway, f, karaokeEnd, ssec, stext } from "./timing2";

/* ------------------------------------------------------------------ */
/* 5 — COMPANION: the pet at a glance, and on your desktop.            */
/*   Storyboards the n_ambient narration:                              */
/*   "leave it in the corner"  -> the desktop widget                   */
/*   "up to at a glance"        -> the fleet ring of Claude sessions    */
/*   "when something matters"   -> a Done and a Needs-you notification  */
/* ------------------------------------------------------------------ */

const CLAUDE_HUE = "#D97757";
const AMBER = "#FFB020";
const clampBoth = { extrapolateLeft: "clamp" as const, extrapolateRight: "clamp" as const };

// Volt, the default pet character, as inline SVG (mirrors the app icon and
// the AttacheApp robot face: steel plate, LED eyes, antenna, mouth).
const Volt2: React.FC<{ size?: number; talking?: boolean }> = ({ size = 170, talking = false }) => {
  const frame = useCurrentFrame();
  const blinkT = frame % 95;
  const openness = blinkT < 3 ? 0.16 : blinkT < 7 ? 0.6 : 1;
  const eyeH = 11 * openness;
  const STEEL = "#C7D0DC", NAVY = "#10243E", LED = "#66E3FF", CORAL = "#FF9DA1";
  return (
    <svg width={size} height={size} viewBox="72 56 96 96" fill="none" style={{ display: "block" }}>
      <line x1="120" y1="82" x2="120" y2="73" stroke={STEEL} strokeWidth={3} strokeLinecap="round" />
      <circle cx="120" cy="69.5" r="3.5" fill={CORAL} />
      <rect x="88" y="82" width="64" height="60" rx="14" fill={STEEL} />
      <rect x="94" y="92" width="52" height="34" rx="8" fill={NAVY} />
      <rect x="99" y={106 - eyeH / 2} width="14" height={eyeH} rx="2.5" fill={LED} />
      <rect x="127" y={106 - eyeH / 2} width="14" height={eyeH} rx="2.5" fill={LED} />
      <circle cx="92.5" cy="119" r="2" fill={CORAL} />
      <circle cx="143.5" cy="119" r="2" fill={CORAL} />
      {talking
        ? [0, 1, 2, 3, 4].map((i) => {
            const h = 3 + 9 * (0.55 + 0.45 * Math.sin(frame / 2.2 + i * 1.3));
            return <rect key={i} x={108 + i * 6 - 1.8} y={134 - h / 2} width="3.6" height={h} rx="1.8" fill={NAVY} />;
          })
        : <rect x="109.2" y="131" width="21.6" height="3.5" rx="1.75" fill={NAVY} />}
    </svg>
  );
};

// Bubbles (the mark face) and Colt (the cowboy), head-only, for the
// character-picker beat. Volt2 is the robot above.
const BubblesHead2: React.FC<{ size?: number }> = ({ size = 120 }) => (
  <svg width={size} height={size} viewBox="82 74 76 76" fill="none" style={{ display: "block" }}>
    <circle cx="120" cy="112" r="33" fill="#FFF6E4" />
    <path d="M97 107 Q105 97 113 107" stroke="#10243E" strokeWidth={5} strokeLinecap="round" />
    <path d="M127 107 Q135 97 143 107" stroke="#10243E" strokeWidth={5} strokeLinecap="round" />
    <circle cx="95" cy="119" r="6" fill="#FF9DA1" opacity={0.6} />
    <circle cx="145" cy="119" r="6" fill="#FF9DA1" opacity={0.6} />
    <path d="M108 119 C 111 134, 129 134, 132 119 Z" fill="#10243E" />
  </svg>
);

const Colt2: React.FC<{ size?: number }> = ({ size = 120 }) => (
  <svg width={size} height={size} viewBox="76 52 88 100" fill="none" style={{ display: "block" }}>
    <circle cx="120" cy="112" r="33" fill="#FFF6E4" />
    <circle cx="95" cy="121" r="6" fill="#FF9DA1" opacity={0.6} />
    <circle cx="145" cy="121" r="6" fill="#FF9DA1" opacity={0.6} />
    <circle cx="106" cy="106" r="7" fill="#fff" /><circle cx="106.5" cy="106.5" r="3.4" fill="#10243E" />
    <circle cx="134" cy="106" r="7" fill="#fff" /><circle cx="134.5" cy="106.5" r="3.4" fill="#10243E" />
    <path d="M110 121 C 113 133, 127 133, 130 121 Z" fill="#10243E" />
    <rect x="99" y="137" width="42" height="9" rx="3" fill="#D13B3B" />
    <path d="M114 143 L 126 143 L 120 152 Z" fill="#D13B3B" />
    <ellipse cx="120" cy="83.5" rx="42" ry="6.5" fill="#734F30" />
    <rect x="101" y="55" width="38" height="27" rx="11" fill="#734F30" />
    <rect x="101" y="73" width="38" height="6" rx="2" fill="#4D3320" />
  </svg>
);

// A macOS-style pointer for the hover and click demos.
const Cursor: React.FC<{ x: number; y: number; clicking?: number }> = ({ x, y, clicking = 0 }) => (
  <div style={{ position: "absolute", left: x, top: y, zIndex: 30, pointerEvents: "none" }}>
    {clicking > 0.02 && (
      <div style={{ position: "absolute", left: 0, top: 0, width: 40 * clicking, height: 40 * clicking, marginLeft: -20 * clicking, marginTop: -20 * clicking, borderRadius: 999, border: "2px solid rgba(255,255,255,0.75)", opacity: 1 - clicking }} />
    )}
    <svg width="30" height="30" viewBox="0 0 26 26" style={{ filter: "drop-shadow(0 2px 4px rgba(0,0,0,0.5))" }}>
      <path d="M3 2 L3 20 L8.2 15.2 L11.4 22 L14.4 20.6 L11.2 14 L18 14 Z" fill="#fff" stroke="#111" strokeWidth="1.3" strokeLinejoin="round" />
    </svg>
  </div>
);

const Pill: React.FC<{ x: number; y: number; text: string; color: string; appear?: number }> = ({ x, y, text, color, appear = 1 }) => (
  <div style={{
    position: "absolute", left: x, top: y, transform: `translate(-50%,-50%) scale(${0.6 + 0.4 * appear})`,
    padding: "4px 12px", borderRadius: 999, whiteSpace: "nowrap",
    background: "rgba(20,20,26,0.72)", border: `1px solid ${color}`, color,
    fontSize: 17, fontWeight: 700, opacity: appear, backdropFilter: "blur(6px)",
  }}>{text}</div>
);

// The fleet ring: Volt centered, Claude session dots orbiting the inner
// track, a focused pin on the outer track, and a Done / Needs-you
// notification that spring in. Frame is scene-relative.
const PetRing: React.FC<{ size?: number; labels?: boolean; doneAt?: number; blockAt?: number; talking?: boolean; focusAngle?: number; character?: "volt" | "bubbles" | "colt" }> = ({
  size = 520, labels = false, doneAt, blockAt, talking = false, focusAngle = Math.PI / 2, character = "volt",
}) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const cx = size / 2, cy = size / 2;
  const Ri = size * 0.34, Ro = size * 0.47;
  const dot = (a: number, r: number) => ({ x: cx + Math.cos(a) * r, y: cy + Math.sin(a) * r });

  const workers = [0, 1, 2, 3].map((i) => {
    const a = (frame / fps) * 0.55 + (i / 4) * Math.PI * 2 + i * 0.5;
    const pos = dot(a, Ri);
    return { ...pos, behind: Math.sin(a) < -0.15, key: i };
  });
  const focus = dot(focusAngle, Ro);
  const done = dot(-Math.PI * 0.72, Ro);
  const block = dot(-Math.PI * 0.28, Ro);
  const spr = (at?: number) => at === undefined ? 0 : spring({ frame: frame - at, fps, config: { damping: 12, mass: 0.6 } });
  const doneP = spr(doneAt);
  const blockP = spr(blockAt);

  const workerDot = (w: { x: number; y: number; key: number }, z: number) => (
    <div key={`w${w.key}`} style={{
      position: "absolute", left: w.x, top: w.y, width: 18, height: 18, borderRadius: 12,
      transform: "translate(-50%,-50%)", background: CLAUDE_HUE, zIndex: z,
      boxShadow: `0 0 10px ${CLAUDE_HUE}88`,
    }} />
  );

  return (
    <div style={{ position: "relative", width: size, height: size }}>
      {/* faint orbit tracks */}
      <svg width={size} height={size} viewBox={`0 0 ${size} ${size}`} style={{ position: "absolute", inset: 0 }}>
        <circle cx={cx} cy={cy} r={Ri} fill="none" stroke="rgba(255,255,255,0.06)" strokeWidth={1.5} />
        <circle cx={cx} cy={cy} r={Ro} fill="none" stroke="rgba(255,255,255,0.05)" strokeWidth={1.5} />
      </svg>
      {workers.filter((w) => w.behind).map((w) => workerDot(w, 1))}
      <div style={{ position: "absolute", left: "50%", top: "50%", transform: "translate(-50%,-50%)", zIndex: 2 }}>
        {character === "bubbles" ? <BubblesHead2 size={size * 0.42} />
          : character === "colt" ? <Colt2 size={size * 0.42} />
          : <Volt2 size={size * 0.42} talking={talking} />}
      </div>
      {workers.filter((w) => !w.behind).map((w) => workerDot(w, 3))}

      {/* focused pin */}
      <div style={{
        position: "absolute", left: focus.x, top: focus.y, width: 26, height: 26, borderRadius: 16,
        transform: "translate(-50%,-50%)", background: "#FFFFFF", border: "3px solid rgba(255,255,255,0.55)",
        boxShadow: "0 0 16px rgba(255,255,255,0.5)", zIndex: 5,
      }} />

      {/* Done notification */}
      {doneAt !== undefined && doneP > 0.02 && (
        <div style={{
          position: "absolute", left: done.x, top: done.y, width: 30, height: 30, borderRadius: 18,
          transform: `translate(-50%,-50%) scale(${doneP})`, background: CLAUDE_HUE, zIndex: 6,
          display: "flex", alignItems: "center", justifyContent: "center",
          color: "#fff", fontSize: 19, fontWeight: 800, boxShadow: `0 0 14px ${CLAUDE_HUE}`,
        }}>✓</div>
      )}
      {/* Needs-you notification */}
      {blockAt !== undefined && blockP > 0.02 && (
        <div style={{
          position: "absolute", left: block.x, top: block.y, width: 30, height: 30, borderRadius: 18,
          transform: `translate(-50%,-50%) scale(${blockP})`, background: AMBER, zIndex: 6,
          display: "flex", alignItems: "center", justifyContent: "center",
          color: "#1a1206", fontSize: 20, fontWeight: 900, boxShadow: `0 0 14px ${AMBER}`,
        }}>?</div>
      )}

      {labels && (
        <>
          <Pill x={focus.x} y={focus.y + 34} text="Focused" color="#FFFFFF" />
          {doneAt !== undefined && doneP > 0.3 && <Pill x={done.x - 4} y={done.y - 32} text="Done" color={CLAUDE_HUE} appear={doneP} />}
          {blockAt !== undefined && blockP > 0.3 && <Pill x={block.x + 4} y={block.y - 32} text="Needs you" color={AMBER} appear={blockP} />}
        </>
      )}
    </div>
  );
};

// A soft macOS desktop wallpaper with a thin menu bar, so the widget beat
// reads as the real desktop rather than the app stage.
const MacDesktop: React.FC<{ children?: React.ReactNode }> = ({ children }) => (
  <AbsoluteFill style={{ background: "linear-gradient(155deg, #2c2660 0%, #6a4b9c 42%, #b56690 74%, #e79a6f 100%)" }}>
    <div style={{
      position: "absolute", top: 0, left: 0, right: 0, height: 34,
      background: "rgba(18,18,26,0.32)", display: "flex", alignItems: "center", gap: 22,
      padding: "0 22px", color: "rgba(255,255,255,0.9)", fontSize: 17, fontWeight: 600,
    }}>
      <div style={{ width: 15, height: 15, borderRadius: 4, background: "rgba(255,255,255,0.9)" }} />
      <span style={{ fontWeight: 800 }}>Finder</span>
      <span style={{ opacity: 0.7 }}>File</span>
      <span style={{ opacity: 0.7 }}>Edit</span>
      <span style={{ opacity: 0.7 }}>View</span>
      <span style={{ marginLeft: "auto", opacity: 0.85 }}>9:41</span>
    </div>
    {children}
  </AbsoluteFill>
);

// Piecewise-linear cursor path over frame waypoints.
const cursorPath = (frame: number, pts: { f: number; x: number; y: number }[]) => {
  if (frame <= pts[0].f) return pts[0];
  for (let i = 0; i < pts.length - 1; i++) {
    if (frame <= pts[i + 1].f) {
      const t = (frame - pts[i].f) / (pts[i + 1].f - pts[i].f);
      const e = t * t * (3 - 2 * t); // smoothstep
      return { x: pts[i].x + (pts[i + 1].x - pts[i].x) * e, y: pts[i].y + (pts[i + 1].y - pts[i].y) * e };
    }
  }
  return pts[pts.length - 1];
};

export const Ambient2: React.FC = () => {
  const frame = useCurrentFrame();
  const charStart = f(ambient.charactersAt);
  const deskOut = interpolate(frame, [82, 102], [1, 0], clampBoth);
  const deskOpacity = Math.min(interpolate(frame, [0, 14], [0, 1], clampBoth), deskOut);
  const appOpacity = Math.min(
    interpolate(frame, [90, 108], [0, 1], clampBoth),
    interpolate(frame, [charStart - 16, charStart], [1, 0], clampBoth)
  );
  const charOpacity = interpolate(frame, [charStart, charStart + 16], [0, 1], clampBoth);
  const breathe = 0.98 + 0.02 * Math.sin(frame / 22);

  // The fleet ring is centered in the centered app window; these are its
  // coordinates in the 1920x1080 frame, for the cursor and tooltip overlays.
  const RCX = 960, RCY = 566, Ri = 540 * 0.34;
  const hoverTarget = { x: RCX + Math.cos(-2.25) * Ri, y: RCY + Math.sin(-2.25) * Ri };
  const clickAngle = 0.5;
  const clickTarget = { x: RCX + Math.cos(clickAngle) * Ri, y: RCY + Math.sin(clickAngle) * Ri };

  const cur = cursorPath(frame, [
    { f: 100, x: RCX + 30, y: RCY + 150 },
    { f: 130, x: hoverTarget.x, y: hoverTarget.y },
    { f: 182, x: hoverTarget.x, y: hoverTarget.y },
    { f: 212, x: clickTarget.x, y: clickTarget.y },
    { f: 300, x: clickTarget.x, y: clickTarget.y },
  ]);
  const clickRipple = interpolate(frame, [214, 232], [0, 1], clampBoth) * interpolate(frame, [214, 216], [0, 1], clampBoth);
  const hoverShown = frame >= 122 && frame < 188;
  // The focus pin slides from its rest spot to the clicked session.
  const focusAngle = interpolate(frame, [214, 244], [Math.PI / 2, clickAngle], clampBoth);

  const capGlance = interpolate(frame, [96, 112, 160, 176], [0, 1, 1, 0], clampBoth);
  const capFocus = interpolate(frame, [176, 190, 232, 246], [0, 1, 1, 0], clampBoth);
  const capSpeak = interpolate(frame, [246, 260, charStart - 16, charStart - 8], [0, 1, 1, 0], clampBoth);

  return (
    <Stage>
      {/* Beat A - leave it in the corner: the desktop widget */}
      <AbsoluteFill style={{ opacity: deskOpacity }}>
        <MacDesktop>
          <div style={{ position: "absolute", right: 118, bottom: 108, filter: "drop-shadow(0 26px 54px rgba(0,0,0,0.42))" }}>
            <PetRing size={392} />
          </div>
          <div style={{ position: "absolute", right: 150, bottom: 58, color: "#fff", fontSize: 26, fontWeight: 700, textShadow: "0 2px 12px rgba(0,0,0,0.5)", opacity: 0.94 }}>
            Lives on your desktop
          </div>
        </MacDesktop>
      </AbsoluteFill>

      {/* Beat B/C - at a glance, hover, click to focus, and it speaks up */}
      <AbsoluteFill style={{ opacity: appOpacity, alignItems: "center", justifyContent: "center" }}>
        <Aurora accent="blue" strength={0.7} />
        <Particles count={20} />
        <AppWindow width={980} style={{ height: 690 }}>
          <div style={{ position: "relative", height: 640, display: "flex", alignItems: "center", justifyContent: "center" }}>
            <div style={{ transform: `scale(${breathe})` }}>
              <PetRing size={540} labels doneAt={232} blockAt={250} focusAngle={focusAngle} />
            </div>
            <div style={{ position: "absolute", left: 0, right: 0, top: 18, textAlign: "center", color: T.text, fontSize: 26, fontWeight: 600, height: 34 }}>
              <span style={{ position: "absolute", left: 0, right: 0, opacity: capGlance }}>Every Claude session it runs, at a glance.</span>
              <span style={{ position: "absolute", left: 0, right: 0, opacity: capFocus }}>Hover to see one, click to focus it.</span>
              <span style={{ position: "absolute", left: 0, right: 0, opacity: capSpeak }}>And it speaks up when one needs you, or finishes.</span>
            </div>
          </div>
        </AppWindow>
        {/* hover: a session held under the cursor, with its title */}
        {hoverShown && (
          <>
            <div style={{ position: "absolute", left: hoverTarget.x, top: hoverTarget.y, width: 18, height: 18, marginLeft: -9, marginTop: -9, borderRadius: 12, background: CLAUDE_HUE, boxShadow: `0 0 12px ${CLAUDE_HUE}`, zIndex: 25 }} />
            <div style={{ position: "absolute", left: hoverTarget.x - 6, top: hoverTarget.y - 44, transform: "translateX(-50%)", padding: "5px 13px", borderRadius: 10, background: "rgba(20,20,26,0.85)", border: "1px solid rgba(255,255,255,0.16)", color: T.text, fontSize: 19, fontWeight: 600, whiteSpace: "nowrap", zIndex: 26 }}>Auth refactor</div>
          </>
        )}
        {frame >= 96 && frame < charStart - 12 && <Cursor x={cur.x} y={cur.y} clicking={clickRipple} />}
      </AbsoluteFill>

      {/* Beat D - make it yours: the character picker */}
      <AbsoluteFill style={{ opacity: charOpacity, alignItems: "center", justifyContent: "center", flexDirection: "column", gap: 40 }}>
        <Aurora accent="blue" strength={0.6} />
        <div style={{ fontSize: 52, fontWeight: 700, color: T.text, letterSpacing: "-0.02em" }}>
          Pick your <span style={{ color: T.gold }}>companion</span>
        </div>
        <div style={{ display: "flex", gap: 48, alignItems: "flex-end" }}>
          {[
            { name: "Bubbles", el: <BubblesHead2 size={150} />, sel: false },
            { name: "Volt", el: <Volt2 size={150} />, sel: true },
            { name: "Colt", el: <Colt2 size={150} />, sel: false },
          ].map((c) => (
            <div key={c.name} style={{ display: "flex", flexDirection: "column", alignItems: "center", gap: 14 }}>
              <div style={{ width: 200, height: 200, borderRadius: 26, display: "flex", alignItems: "center", justifyContent: "center", background: c.sel ? "rgba(10,132,255,0.12)" : T.bgPanel, border: `2px solid ${c.sel ? T.gold : T.stroke}`, boxShadow: c.sel ? `0 0 40px rgba(10,132,255,0.35)` : "none" }}>
                {c.el}
              </div>
              <span style={{ color: c.sel ? T.gold : T.dim, fontSize: 26, fontWeight: c.sel ? 700 : 600 }}>{c.name}</span>
            </div>
          ))}
        </div>
      </AbsoluteFill>
      <LightSweep start={12} dur={60} opacity={0.05} />
    </Stage>
  );
};

/* ------------------------------------------------------------------ */
/* 6 — LIVE: talk to it; the composer shows what it's doing, unnarrated. */
/* ------------------------------------------------------------------ */

export const Live2: React.FC = () => {
  const frame = useCurrentFrame();
  const composerF = f(live.composerAt);
  const listenF = f(live.listenAt);
  const thinkF = f(live.thinkAt);
  const prepF = f(live.prepAt);
  const speakF = f(live.speakAt);
  const thinkSecs = Math.max(1, Math.floor((frame - thinkF) / FPS) + 1);
  const windowIn = interpolate(frame, [0, 14], [0, 1], { extrapolateLeft: "clamp", extrapolateRight: "clamp" });

  let status: React.ReactNode = null;
  if (frame >= speakF) status = <StatusRow icon="speaker" text="Speaking…" />;
  else if (frame >= prepF) status = <StatusRow icon="waveform" text="Preparing audio…" />;
  else if (frame >= thinkF) status = <StatusRow icon="spinner" text={`Thinking… ${thinkSecs}s`} />;
  else if (frame >= listenF) status = <StatusRow icon="mic" text="Listening…" />;

  const speaking = frame >= speakF;
  return (
    <Stage>
      <Aurora accent="violet" strength={0.9} />
      <Particles count={26} />
      <RingPulse at={composerF} />
      <AbsoluteFill style={{ alignItems: "center", justifyContent: "center", opacity: windowIn }}>
        <AppWindow width={1180} live={frame >= composerF}>
          <div style={{ padding: "30px 34px 30px", display: "flex", flexDirection: "column", gap: 26, minHeight: 430, justifyContent: "space-between" }}>
            <div style={{ display: "flex", flexDirection: "column", alignItems: "center", gap: 24, paddingTop: 16 }}>
              <Volt2 size={150} talking={speaking} />
              {frame >= listenF && frame < thinkF && (
                <>
                  <WaveBars n={26} height={30} color="rgba(242,242,245,0.75)" />
                  <div style={{ color: T.text, fontSize: 27, fontWeight: 600 }}>“Which clip performed best?”</div>
                </>
              )}
              {speaking && (
                <div style={{ width: 900 }}>
                  <WordSweep
                    text={stext("va_live")}
                    startFrame={speakF + 2}
                    endFrame={speakF + karaokeEnd(ssec("va_live"))}
                    fontSize={30}
                    align="center"
                  />
                </div>
              )}
            </div>
            <div style={{ display: "flex", justifyContent: "center" }}>
              {frame >= composerF && <Composer width={1050} destination="attache" status={status} />}
            </div>
          </div>
        </AppWindow>
      </AbsoluteFill>
      <LightSweep start={composerF} dur={44} opacity={0.07} />
    </Stage>
  );
};

/* ------------------------------------------------------------------ */
/* 7 — TWO-WAY: tell the agent its next move; the indicators are real. */
/* ------------------------------------------------------------------ */

const INSTRUCTION = "Post clip two and schedule the rest, one a day at nine.";
const TARGET = "Codex · episode 14 pipeline";

export const TwoWay2: React.FC = () => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();

  const chipFlipF = f(twoway.chipFlipAt);
  const typedF = f(twoway.typedAt);
  const typedDurF = f(twoway.typedDur);
  const confirmF = f(twoway.confirmAt);
  const sendPressF = f(twoway.sendPressAt);
  const queuedF = f(twoway.queuedAt);
  const quietF = f(twoway.quietAt);
  const deliverTypeF = f(twoway.deliverTypeAt);
  const deliveredF = f(twoway.deliveredAt);
  const waitingF = f(twoway.waitingAt);
  const replyPrintF = f(twoway.replyPrintAt);
  const replyCardF = f(twoway.replyCardAt);
  const replySpeakF = f(twoway.replySpeakAt);

  const termLines: TermLine[] = [
    { at: 0, text: "▸ codex — episode 14 pipeline" },
    { at: 8, text: "▸ exporting caption files…" },
    { at: Math.round(quietF * 0.55), text: "▸ uploading renders…" },
    { at: quietF, text: "✓ turn complete — session quiet", color: "#30D158" },
    { at: deliverTypeF, text: `> attaché: ${INSTRUCTION}`, color: "#FF9F0A", type: true },
    { at: replyPrintF, text: "▸ posting clip 2 … done", color: T.dim },
    { at: replyPrintF + 12, text: "▸ scheduling 4 posts … done", color: T.dim },
    { at: replyPrintF + 24, text: "codex: Clip two is posted. Four scheduled, daily at 9:00.", color: "#30D158" },
  ];

  const composerTyped = typeSlice(INSTRUCTION, frame, typedF, typedDurF);
  const agentMode = frame >= chipFlipF;

  const queuedSecs = Math.max(1, Math.floor((frame - queuedF) / FPS) + 1);
  const waitingSecs = Math.max(1, Math.floor((frame - deliveredF) / FPS) + 1);
  let status: React.ReactNode = null;
  if (frame >= queuedF && frame < deliveredF) {
    status = <StatusRow icon="spinner" text={`Sending to Codex when the session is quiet… ${queuedSecs}s`} />;
  } else if (frame >= deliveredF && frame < waitingF) {
    status = <StatusRow icon="check" emphasis text="Sent to Codex · watching for the reply" />;
  } else if (frame >= waitingF && frame < replyCardF + 10) {
    status = <StatusRow icon="spinner" text={`Waiting for Codex to reply… ${waitingSecs}s`} />;
  }
  // After the reply is linked, the row goes idle — exactly like the app.

  const confirmP = spring({ frame: frame - confirmF, fps, config: { damping: 16, mass: 0.8 } });
  const confirmGone = interpolate(frame, [sendPressF + 8, sendPressF + 18], [1, 0], { extrapolateLeft: "clamp", extrapolateRight: "clamp" });
  const pressed = frame >= sendPressF && frame < sendPressF + 10;
  const replyP = spring({ frame: frame - replyCardF, fps, config: { damping: 15, mass: 0.9 } });
  const replySpeaking = frame >= replySpeakF;

  return (
    <Stage>
      <Aurora accent="ember" strength={0.7} />
      <Particles count={22} />
      <Camera from={1} to={1.035} over={f(twoway.len)}>
        <AbsoluteFill style={{ alignItems: "center", justifyContent: "center" }}>
          <div style={{ display: "flex", gap: 46, alignItems: "stretch" }}>
            <div style={{ display: "flex", flexDirection: "column", gap: 16 }}>
              <Terminal width={840} title="codex — episode 14 pipeline" lines={termLines} tilt={4} minHeight={430} fontSize={21} />
            </div>

            <AppWindow width={880} live style={{ alignSelf: "center" }}>
              <div style={{ padding: "26px 28px 28px", display: "flex", flexDirection: "column", gap: 20, minHeight: 470, justifyContent: "flex-end" }}>
                {frame >= confirmF && confirmGone > 0 && (
                  <div
                    style={{
                      borderRadius: 16, padding: "22px 26px",
                      background: "rgba(255,159,10,0.08)", border: "1px solid rgba(255,159,10,0.5)",
                      opacity: confirmP * confirmGone,
                      transform: `translateY(${(1 - confirmP) * 36}px)`,
                    }}
                  >
                    <div style={{ display: "flex", alignItems: "center", gap: 10, marginBottom: 12 }}>
                      <span style={{ color: "#FF9F0A", fontSize: 22, fontWeight: 700 }}>Send to {TARGET}?</span>
                    </div>
                    <div style={{ color: T.text, fontSize: 24, lineHeight: 1.45, marginBottom: 18 }}>“{INSTRUCTION}”</div>
                    <div style={{ display: "flex", gap: 12, justifyContent: "flex-end" }}>
                      <span style={{ padding: "9px 22px", borderRadius: 11, background: "rgba(255,255,255,0.07)", color: T.dim, fontSize: 21, fontWeight: 600 }}>Cancel</span>
                      <span
                        style={{
                          padding: "9px 26px", borderRadius: 11, fontSize: 21, fontWeight: 700,
                          background: pressed ? "#FFB84D" : "#FF9F0A", color: "#1A1104",
                          transform: pressed ? "scale(0.94)" : "none",
                          boxShadow: pressed ? "0 0 30px rgba(255,159,10,0.7)" : "0 4px 18px rgba(255,159,10,0.35)",
                        }}
                      >
                        Send
                      </span>
                    </div>
                  </div>
                )}

                {frame >= replyCardF && (
                  <div
                    style={{
                      borderRadius: 16, padding: "22px 26px",
                      background: "rgba(10,132,255,0.09)", border: `1px solid ${T.gold}`,
                      boxShadow: "0 0 46px rgba(10,132,255,0.18)",
                      opacity: replyP,
                      transform: `translateY(${(1 - replyP) * 36}px)`,
                    }}
                  >
                    <div style={{ display: "flex", alignItems: "center", gap: 12, marginBottom: 12 }}>
                      <span style={{ color: T.gold, fontSize: 21, fontWeight: 700 }}>Reply from Codex</span>
                      <span style={{ color: T.faint, fontSize: 18 }}>· just now</span>
                      {replySpeaking && <div style={{ marginLeft: "auto" }}><WaveBars n={12} height={20} barWidth={4} /></div>}
                    </div>
                    <WordSweep
                      text={stext("va_reply")}
                      startFrame={replySpeakF + 2}
                      endFrame={replySpeakF + karaokeEnd(ssec("va_reply"))}
                      fontSize={25}
                    />
                  </div>
                )}

                <Composer
                  width={820}
                  destination={agentMode ? "agent" : "attache"}
                  target={TARGET}
                  typed={frame >= sendPressF + 14 ? "" : composerTyped}
                  caret={frame >= typedF && frame < sendPressF}
                  status={status}
                />
              </div>
            </AppWindow>
          </div>
        </AbsoluteFill>
      </Camera>
      <LightSweep start={deliveredF} dur={36} opacity={0.08} />
    </Stage>
  );
};
