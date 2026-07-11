import React from "react";
import { AbsoluteFill, interpolate, random, spring, useCurrentFrame, useVideoConfig } from "remotion";
import { T } from "../theme";

/* ------------------------------------------------------------------ */
/* Cinematic layers                                                    */
/* ------------------------------------------------------------------ */

/**
 * Aurora: slow-drifting colored washes over the dark ground. Keeps the black
 * base (text and UI chrome still pop) but kills the flat, vanilla look —
 * every scene sits on moving color instead of plain near-black.
 */
export const Aurora: React.FC<{ accent?: "blue" | "violet" | "teal" | "ember"; strength?: number }> = ({ accent = "blue", strength = 1 }) => {
  const frame = useCurrentFrame();
  const drift = (speed: number, amp: number, phase: number) =>
    Math.sin(frame / speed + phase) * amp;
  const palettes: Record<string, [string, string, string]> = {
    blue: ["10,132,255", "94,92,230", "0,199,190"],
    violet: ["122,92,255", "10,132,255", "191,90,242"],
    teal: ["0,199,190", "10,132,255", "48,209,88"],
    ember: ["255,159,10", "255,69,58", "122,92,255"],
  };
  const [a, b, c] = palettes[accent];
  return (
    <AbsoluteFill style={{ pointerEvents: "none" }}>
      <div
        style={{
          position: "absolute", width: 1700, height: 1300, borderRadius: "50%",
          left: -420 + drift(210, 90, 0), top: -560 + drift(260, 70, 1.3),
          background: `radial-gradient(closest-side, rgba(${a},${0.17 * strength}), transparent 70%)`,
        }}
      />
      <div
        style={{
          position: "absolute", width: 1500, height: 1200, borderRadius: "50%",
          right: -460 + drift(240, 100, 2.1), bottom: -520 + drift(200, 80, 0.6),
          background: `radial-gradient(closest-side, rgba(${b},${0.13 * strength}), transparent 70%)`,
        }}
      />
      <div
        style={{
          position: "absolute", width: 1100, height: 900, borderRadius: "50%",
          right: 60 + drift(190, 120, 4.0), top: -420 + drift(230, 60, 2.8),
          background: `radial-gradient(closest-side, rgba(${c},${0.09 * strength}), transparent 70%)`,
        }}
      />
    </AbsoluteFill>
  );
};

/** Slow-drifting depth-sorted particle field. Deterministic via remotion random(). */
export const Particles: React.FC<{ count?: number; tint?: string }> = ({ count = 46, tint = "10,132,255" }) => {
  const frame = useCurrentFrame();
  return (
    <AbsoluteFill style={{ pointerEvents: "none" }}>
      {Array.from({ length: count }).map((_, i) => {
        const depth = 0.3 + 0.7 * random(`d${i}`); // 0.3 near, 1 far
        const x = random(`x${i}`) * 1920;
        const y0 = random(`y${i}`) * 1080;
        const speed = 0.12 + 0.3 * (1 - depth);
        const y = ((y0 - frame * speed) % 1140 + 1140) % 1140 - 30;
        const size = (1 - depth) * 5 + 1.2;
        const tw = 0.5 + 0.5 * Math.sin(frame / 30 + i * 2.1);
        const op = (0.05 + 0.16 * (1 - depth)) * (0.6 + 0.4 * tw);
        return (
          <div
            key={i}
            style={{
              position: "absolute", left: x, top: y, width: size, height: size,
              borderRadius: 999, background: `rgba(${tint},${op})`,
              boxShadow: size > 3.4 ? `0 0 ${size * 3}px rgba(${tint},${op * 0.8})` : "none",
            }}
          />
        );
      })}
    </AbsoluteFill>
  );
};

/** A diagonal light band sweeping across the frame once over [start, start+dur]. */
export const LightSweep: React.FC<{ start: number; dur?: number; opacity?: number }> = ({ start, dur = 40, opacity = 0.10 }) => {
  const frame = useCurrentFrame();
  const p = interpolate(frame, [start, start + dur], [-0.4, 1.4], { extrapolateLeft: "clamp", extrapolateRight: "clamp" });
  if (p <= -0.4 || p >= 1.4) return null;
  return (
    <AbsoluteFill style={{ pointerEvents: "none", overflow: "hidden" }}>
      <div
        style={{
          position: "absolute", top: -200, bottom: -200, width: 460,
          left: `${p * 100}%`, transform: "rotate(14deg)",
          background: `linear-gradient(90deg, transparent, rgba(255,255,255,${opacity}), transparent)`,
          mixBlendMode: "screen",
        }}
      />
    </AbsoluteFill>
  );
};

/** Slow camera push/pull on everything inside. */
export const Camera: React.FC<{ from?: number; to?: number; over: number; children: React.ReactNode }> = ({ from = 1, to = 1.06, over, children }) => {
  const frame = useCurrentFrame();
  const s = interpolate(frame, [0, over], [from, to], { extrapolateLeft: "clamp", extrapolateRight: "clamp" });
  return <AbsoluteFill style={{ transform: `scale(${s})` }}>{children}</AbsoluteFill>;
};

/** Scene shell: dissolve+drift in over the first edge frames, out over the last. */
export const Shell: React.FC<{ duration: number; edge?: number; children: React.ReactNode }> = ({ duration, edge = 14, children }) => {
  const frame = useCurrentFrame();
  const op = interpolate(frame, [0, edge, duration - edge, duration], [0, 1, 1, 0], { extrapolateLeft: "clamp", extrapolateRight: "clamp" });
  const scaleIn = interpolate(frame, [0, edge], [1.035, 1], { extrapolateLeft: "clamp", extrapolateRight: "clamp" });
  const scaleOut = interpolate(frame, [duration - edge, duration], [1, 1.02], { extrapolateLeft: "clamp", extrapolateRight: "clamp" });
  return (
    <AbsoluteFill style={{ opacity: op, transform: `scale(${scaleIn * scaleOut})` }}>
      {children}
    </AbsoluteFill>
  );
};

/** Ring pulse (e.g. the go-live moment): expanding fading circles. */
export const RingPulse: React.FC<{ at: number; cx?: string; cy?: string; color?: string }> = ({ at, cx = "50%", cy = "50%", color = T.gold }) => {
  const frame = useCurrentFrame();
  return (
    <AbsoluteFill style={{ pointerEvents: "none" }}>
      {[0, 10, 20].map((d) => {
        const t = frame - at - d;
        if (t < 0 || t > 46) return null;
        const r = interpolate(t, [0, 46], [40, 760]);
        const op = interpolate(t, [0, 8, 46], [0, 0.32, 0]);
        return (
          <div
            key={d}
            style={{
              position: "absolute", left: cx, top: cy, width: r * 2, height: r * 2,
              marginLeft: -r, marginTop: -r, borderRadius: 999,
              border: `2px solid ${color}`, opacity: op,
            }}
          />
        );
      })}
    </AbsoluteFill>
  );
};

/* ------------------------------------------------------------------ */
/* Icons (frame-driven, no CSS animation)                              */
/* ------------------------------------------------------------------ */

export const Spinner: React.FC<{ size?: number; color?: string }> = ({ size = 26, color = T.gold }) => {
  const frame = useCurrentFrame();
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" style={{ transform: `rotate(${frame * 14}deg)`, flexShrink: 0 }}>
      <circle cx="12" cy="12" r="9" stroke={color} strokeOpacity="0.22" strokeWidth="3" fill="none" />
      <path d="M12 3 a 9 9 0 0 1 9 9" stroke={color} strokeWidth="3" fill="none" strokeLinecap="round" />
    </svg>
  );
};

export const IconCheck: React.FC<{ size?: number; color?: string }> = ({ size = 26, color = "#30D158" }) => (
  <svg width={size} height={size} viewBox="0 0 24 24" style={{ flexShrink: 0 }}>
    <circle cx="12" cy="12" r="11" fill={color} />
    <path d="M7 12.5 L10.5 16 L17 8.5" stroke="#0A0A0D" strokeWidth="2.6" fill="none" strokeLinecap="round" strokeLinejoin="round" />
  </svg>
);

export const IconMic: React.FC<{ size?: number; color?: string }> = ({ size = 26, color = T.gold }) => (
  <svg width={size} height={size} viewBox="0 0 24 24" fill={color} style={{ flexShrink: 0 }}>
    <rect x="9" y="2.5" width="6" height="12" rx="3" />
    <path d="M5.5 11.5 a 6.5 6.5 0 0 0 13 0" stroke={color} strokeWidth="2" fill="none" strokeLinecap="round" />
    <rect x="11" y="18" width="2" height="3.4" rx="1" />
  </svg>
);

export const IconSpeaker: React.FC<{ size?: number; color?: string }> = ({ size = 26, color = T.gold }) => {
  const frame = useCurrentFrame();
  const w1 = 0.5 + 0.5 * Math.sin(frame / 4);
  const w2 = 0.5 + 0.5 * Math.sin(frame / 4 + 1.4);
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" style={{ flexShrink: 0 }}>
      <path d="M4 9 h4 l5 -4.5 v15 L8 15 H4 z" fill={color} />
      <path d="M15.5 9 a 4.5 4.5 0 0 1 0 6" stroke={color} strokeWidth="2" fill="none" strokeLinecap="round" opacity={0.35 + 0.65 * w1} />
      <path d="M18 6.6 a 8 8 0 0 1 0 10.8" stroke={color} strokeWidth="2" fill="none" strokeLinecap="round" opacity={0.35 + 0.65 * w2} />
    </svg>
  );
};

export const IconWaveform: React.FC<{ size?: number; color?: string }> = ({ size = 26, color = T.gold }) => {
  const frame = useCurrentFrame();
  const hs = [0.5, 0.9, 0.65, 1, 0.55];
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" style={{ flexShrink: 0 }}>
      {hs.map((h, i) => {
        const hh = 16 * h * (0.7 + 0.3 * Math.sin(frame / 4 + i * 1.3));
        return <rect key={i} x={2.6 + i * 4.2} y={12 - hh / 2} width={2.6} height={hh} rx={1.3} fill={color} />;
      })}
    </svg>
  );
};

export const IconLock: React.FC<{ size?: number; color?: string }> = ({ size = 22, color = T.gold }) => (
  <svg width={size} height={size} viewBox="0 0 24 24" fill={color} style={{ flexShrink: 0 }}>
    <rect x="5" y="10.5" width="14" height="10" rx="2.6" />
    <path d="M8 10.5 V8 a 4 4 0 0 1 8 0 v2.5" stroke={color} strokeWidth="2.4" fill="none" />
  </svg>
);

/* ------------------------------------------------------------------ */
/* App-realistic building blocks                                       */
/* ------------------------------------------------------------------ */

/** Glassy Attaché window chrome: traffic lights, centered title, LIVE slot. */
export const AppWindow: React.FC<{
  width: number;
  live?: boolean;
  children: React.ReactNode;
  style?: React.CSSProperties;
}> = ({ width, live, children, style }) => (
  <div
    style={{
      width, borderRadius: 18, overflow: "hidden",
      border: `1px solid rgba(255,255,255,0.14)`,
      background: "linear-gradient(180deg, rgba(30,30,38,0.92), rgba(19,19,25,0.94))",
      boxShadow: "0 60px 130px rgba(0,0,0,0.65), inset 0 1px 0 rgba(255,255,255,0.08)",
      ...style,
    }}
  >
    <div style={{ position: "relative", display: "flex", alignItems: "center", padding: "13px 16px", background: "rgba(255,255,255,0.045)", borderBottom: `1px solid rgba(255,255,255,0.07)` }}>
      <div style={{ display: "flex", gap: 8 }}>
        {["#FF5F57", "#FEBC2E", "#28C840"].map((c) => (
          <div key={c} style={{ width: 13, height: 13, borderRadius: 7, background: c, opacity: 0.92 }} />
        ))}
      </div>
      <div style={{ position: "absolute", left: 0, right: 0, textAlign: "center", color: T.dim, fontSize: 22, fontWeight: 600, pointerEvents: "none" }}>
        Attaché
      </div>
      {live && (
        <div style={{ marginLeft: "auto", display: "flex", alignItems: "center", gap: 8, padding: "4px 14px", borderRadius: 999, background: "rgba(255,69,58,0.16)", border: "1px solid rgba(255,69,58,0.55)" }}>
          <LiveDot />
          <span style={{ color: "#FF6961", fontSize: 19, fontWeight: 800, letterSpacing: "0.06em" }}>LIVE</span>
        </div>
      )}
    </div>
    {children}
  </div>
);

const LiveDot: React.FC = () => {
  const frame = useCurrentFrame();
  const p = 0.55 + 0.45 * Math.sin(frame / 6);
  return <div style={{ width: 10, height: 10, borderRadius: 6, background: "#FF453A", opacity: p, boxShadow: `0 0 ${8 * p}px rgba(255,69,58,0.8)` }} />;
};

/** Source chip, e.g. "Codex" / "Claude Code". */
export const SourceChip: React.FC<{ label: string; color?: string }> = ({ label, color = T.dim }) => (
  <div style={{ display: "inline-flex", alignItems: "center", gap: 8, padding: "4px 13px", borderRadius: 999, background: "rgba(255,255,255,0.06)", border: `1px solid ${T.stroke}` }}>
    <div style={{ width: 8, height: 8, borderRadius: 5, background: color }} />
    <span style={{ color: T.dim, fontSize: 19, fontWeight: 600 }}>{label}</span>
  </div>
);

/** Animated playback equalizer bars. */
export const WaveBars: React.FC<{ n?: number; height?: number; color?: string; barWidth?: number }> = ({ n = 22, height = 26, color = T.gold, barWidth = 4.5 }) => {
  const frame = useCurrentFrame();
  return (
    <div style={{ display: "flex", gap: barWidth * 0.8, alignItems: "flex-end", height }}>
      {Array.from({ length: n }).map((_, b) => {
        const h = height * (0.22 + 0.78 * Math.abs(Math.sin(frame / 3.6 + b * 0.9) * Math.sin(frame / 9 + b * 0.31)));
        return <div key={b} style={{ width: barWidth, borderRadius: barWidth * 0.6, background: color, height: Math.max(4, h) }} />;
      })}
    </div>
  );
};

/** The call composer's status row: icon + text, exactly one line, like CallHUD. */
export const StatusRow: React.FC<{
  icon: "spinner" | "mic" | "speaker" | "waveform" | "check";
  text: string;
  emphasis?: boolean;
}> = ({ icon, text, emphasis }) => (
  <div
    style={{
      display: "flex", alignItems: "center", gap: 13, padding: "10px 18px",
      borderRadius: 12,
      background: emphasis ? "rgba(48,209,88,0.12)" : "rgba(255,255,255,0.045)",
      border: `1px solid ${emphasis ? "rgba(48,209,88,0.55)" : T.stroke}`,
    }}
  >
    {icon === "spinner" && <Spinner size={24} />}
    {icon === "mic" && <IconMic size={24} />}
    {icon === "speaker" && <IconSpeaker size={24} />}
    {icon === "waveform" && <IconWaveform size={24} />}
    {icon === "check" && <IconCheck size={24} />}
    <span style={{ color: emphasis ? "#4CD964" : T.text, fontSize: 23, fontWeight: 600, fontVariantNumeric: "tabular-nums", whiteSpace: "nowrap" }}>{text}</span>
  </div>
);

/** The call composer bar: destination chip, input field, mic, status row below. */
export const Composer: React.FC<{
  width: number;
  destination: "attache" | "agent";
  target?: string;
  typed?: string;
  caret?: boolean;
  status?: React.ReactNode;
}> = ({ width, destination, target, typed = "", caret = false, status }) => {
  const frame = useCurrentFrame();
  const caretOn = Math.floor(frame / 14) % 2 === 0;
  const agent = destination === "agent";
  return (
    <div style={{ width, display: "flex", flexDirection: "column", gap: 12 }}>
      <div style={{ display: "flex", alignItems: "center", gap: 12 }}>
        <div
          style={{
            display: "flex", alignItems: "center", gap: 9, padding: "7px 16px", borderRadius: 999,
            background: agent ? "rgba(255,159,10,0.14)" : T.goldSoft,
            border: `1px solid ${agent ? "#FF9F0A" : T.gold}`,
          }}
        >
          <span style={{ color: agent ? "#FF9F0A" : T.gold, fontSize: 20, fontWeight: 700 }}>
            {agent ? "Tell Agent" : "Ask Attaché"}
          </span>
        </div>
        {agent && target && (
          <div style={{ display: "flex", alignItems: "center", gap: 8, padding: "7px 14px", borderRadius: 999, background: "rgba(255,255,255,0.05)", border: `1px solid ${T.stroke}` }}>
            <IconLock size={17} color="#FF9F0A" />
            <span style={{ color: T.dim, fontSize: 19, fontWeight: 600 }}>{target}</span>
          </div>
        )}
      </div>
      <div
        style={{
          display: "flex", alignItems: "center", gap: 14, padding: "16px 20px", borderRadius: 16,
          background: "rgba(255,255,255,0.055)", border: `1px solid rgba(255,255,255,0.13)`,
          boxShadow: "inset 0 1px 0 rgba(255,255,255,0.06)",
        }}
      >
        <IconMic size={26} color={typed ? T.dim : T.gold} />
        <span style={{ color: typed ? T.text : T.faint, fontSize: 25, flex: 1, whiteSpace: "nowrap", overflow: "hidden" }}>
          {typed || "Talk, or type a message…"}
          {caret && <span style={{ opacity: caretOn ? 1 : 0, color: T.gold }}>▍</span>}
        </span>
      </div>
      {status && <div style={{ display: "flex" }}>{status}</div>}
    </div>
  );
};

/** A terminal window with typed log lines, optionally tilted in 3D. */
export type TermLine = { at: number; text: string; color?: string; type?: boolean };
export const Terminal: React.FC<{
  width: number;
  title: string;
  lines: TermLine[];
  tilt?: number; // deg rotateY
  minHeight?: number;
  fontSize?: number;
  style?: React.CSSProperties;
}> = ({ width, title, lines, tilt = 0, minHeight = 300, fontSize = 22, style }) => {
  const frame = useCurrentFrame();
  const visible = lines.filter((l) => frame >= l.at);
  return (
    <div style={{ perspective: 1400 }}>
      <div
        style={{
          width, borderRadius: 14, overflow: "hidden",
          transform: tilt ? `rotateY(${tilt}deg)` : undefined,
          border: `1px solid ${T.stroke}`,
          background: "linear-gradient(180deg, rgba(24,24,30,0.96), rgba(15,15,20,0.97))",
          boxShadow: "0 46px 100px rgba(0,0,0,0.62)",
          ...style,
        }}
      >
        <div style={{ position: "relative", display: "flex", alignItems: "center", padding: "11px 14px", background: "rgba(255,255,255,0.04)" }}>
          <div style={{ display: "flex", gap: 7 }}>
            {["#FF5F57", "#FEBC2E", "#28C840"].map((c) => (
              <div key={c} style={{ width: 11, height: 11, borderRadius: 6, background: c, opacity: 0.85 }} />
            ))}
          </div>
          <div style={{ position: "absolute", left: 0, right: 0, textAlign: "center", color: T.faint, fontSize: 18, fontFamily: T.mono }}>{title}</div>
        </div>
        <div style={{ padding: "18px 22px 22px", fontFamily: T.mono, fontSize, minHeight, lineHeight: 1.65 }}>
          {visible.map((l, i) => {
            const isLast = i === visible.length - 1;
            let text = l.text;
            if (l.type) {
              const chars = Math.max(0, Math.floor((frame - l.at) / 0.8));
              text = l.text.slice(0, chars);
            }
            return (
              <div key={`${l.at}-${i}`} style={{ color: l.color ?? T.dim, opacity: isLast ? 1 : 0.62, whiteSpace: "pre-wrap" }}>
                {text}
                {isLast && Math.floor(frame / 12) % 2 === 0 ? <span style={{ color: T.faint }}> ▍</span> : null}
              </div>
            );
          })}
        </div>
      </div>
    </div>
  );
};

/** Session activity pill for the terminal: working (amber pulse) vs idle. */
export const ActivityPill: React.FC<{ busyUntil: number }> = ({ busyUntil }) => {
  const frame = useCurrentFrame();
  const busy = frame < busyUntil;
  const p = 0.5 + 0.5 * Math.sin(frame / 5);
  return (
    <div style={{ display: "inline-flex", alignItems: "center", gap: 9, padding: "6px 15px", borderRadius: 999, background: "rgba(255,255,255,0.05)", border: `1px solid ${T.stroke}` }}>
      <div style={{ width: 9, height: 9, borderRadius: 5, background: busy ? "#FF9F0A" : "#30D158", opacity: busy ? 0.5 + 0.5 * p : 1 }} />
      <span style={{ color: T.dim, fontSize: 19, fontWeight: 600 }}>{busy ? "session busy" : "session quiet"}</span>
    </div>
  );
};

/** Glassy feature chip for the trust beat. */
export const GlassChip: React.FC<{ icon: React.ReactNode; title: string; sub: string; delay: number }> = ({ icon, title, sub, delay }) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const p = spring({ frame: frame - delay, fps, config: { damping: 16, mass: 0.9 } });
  return (
    <div
      style={{
        width: 480, padding: "34px 34px 30px", borderRadius: 24, boxSizing: "border-box",
        background: "linear-gradient(160deg, rgba(255,255,255,0.075), rgba(255,255,255,0.028))",
        border: `1px solid rgba(255,255,255,0.14)`,
        boxShadow: "0 40px 90px rgba(0,0,0,0.5), inset 0 1px 0 rgba(255,255,255,0.1)",
        opacity: p,
        transform: `translateY(${(1 - p) * 60}px) rotateX(${(1 - p) * -14}deg)`,
      }}
    >
      <div style={{ marginBottom: 18 }}>{icon}</div>
      <div style={{ color: T.text, fontSize: 32, fontWeight: 700, marginBottom: 10 }}>{title}</div>
      <div style={{ color: T.dim, fontSize: 23, lineHeight: 1.45 }}>{sub}</div>
    </div>
  );
};

/** Typewriter helper: how many characters of `text` are visible. */
export const typed = (text: string, frame: number, startFrame: number, durFrames: number): string => {
  const p = Math.max(0, Math.min(1, (frame - startFrame) / durFrames));
  return text.slice(0, Math.round(p * text.length));
};

/**
 * Inline karaoke: words light up over [startFrame, endFrame], no pill chrome,
 * so it can sit inside a card the way captions sit inside the real app.
 */
export const WordSweep: React.FC<{
  text: string;
  startFrame: number;
  endFrame: number;
  fontSize?: number;
  align?: "left" | "center";
}> = ({ text, startFrame, endFrame, fontSize = 27, align = "left" }) => {
  const frame = useCurrentFrame();
  const words = text.split(" ");
  const per = (endFrame - startFrame) / words.length;
  const active = Math.floor((frame - startFrame) / per);
  return (
    <div style={{ fontSize, lineHeight: 1.5, fontWeight: 600, textAlign: align }}>
      {words.map((w, i) => (
        <span key={i} style={{ color: i < active ? T.text : i === active ? T.gold : T.faint }}>
          {w}{" "}
        </span>
      ))}
    </div>
  );
};

/** Circular-arrows fallback icon for the trust beat. */
export const IconCycle: React.FC<{ size?: number; color?: string }> = ({ size = 34, color = T.gold }) => (
  <svg width={size} height={size} viewBox="0 0 24 24" fill="none" style={{ flexShrink: 0 }}>
    <path d="M20 12 a 8 8 0 1 1 -2.6 -5.9" stroke={color} strokeWidth="2.4" strokeLinecap="round" />
    <path d="M17 2.6 L17.6 6.5 L13.7 7.1" stroke={color} strokeWidth="2.4" strokeLinecap="round" strokeLinejoin="round" fill="none" />
  </svg>
);

/** Tiny session card for the wall-of-agents hook beat. */
export const MiniSession: React.FC<{ title: string; line: string; delay: number; tint?: string }> = ({ title, line, delay, tint = "10,132,255" }) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const p = spring({ frame: frame - delay, fps, config: { damping: 15, mass: 0.7 } });
  const blink = Math.floor((frame - delay) / 16) % 2 === 0;
  return (
    <div
      style={{
        borderRadius: 11, overflow: "hidden", border: `1px solid rgba(255,255,255,0.09)`,
        background: "linear-gradient(180deg, rgba(26,26,33,0.94), rgba(16,16,21,0.95))",
        boxShadow: `0 18px 44px rgba(0,0,0,0.5), 0 0 24px rgba(${tint},0.05)`,
        opacity: p, transform: `translateY(${(1 - p) * 40}px) scale(${0.92 + p * 0.08})`,
      }}
    >
      <div style={{ display: "flex", alignItems: "center", gap: 6, padding: "7px 10px", background: "rgba(255,255,255,0.035)" }}>
        {["#FF5F57", "#FEBC2E", "#28C840"].map((cc) => (
          <div key={cc} style={{ width: 7, height: 7, borderRadius: 4, background: cc, opacity: 0.8 }} />
        ))}
        <span style={{ marginLeft: 4, color: T.faint, fontSize: 14.5, fontFamily: T.mono, whiteSpace: "nowrap", overflow: "hidden" }}>{title}</span>
      </div>
      <div style={{ padding: "9px 12px 11px", fontFamily: T.mono, fontSize: 14.5, color: T.dim, whiteSpace: "nowrap", overflow: "hidden" }}>
        {line}
        {blink ? " ▍" : ""}
      </div>
    </div>
  );
};

/** Voicemail media controls: skip-back, play/pause, skip-forward, speed, replay. */
export const MediaControls: React.FC<{ playing: boolean; speed: string; speedActive: boolean }> = ({ playing, speed, speedActive }) => {
  const btn: React.CSSProperties = {
    width: 46, height: 46, borderRadius: 999, display: "flex", alignItems: "center", justifyContent: "center",
    background: "rgba(255,255,255,0.07)", border: `1px solid ${T.stroke}`, color: T.text, fontSize: 19, fontWeight: 700,
  };
  return (
    <div style={{ display: "flex", alignItems: "center", gap: 12 }}>
      <div style={btn}>
        <svg width="22" height="22" viewBox="0 0 24 24" fill="none"><path d="M11 5 L4 12 L11 19 M20 5 L13 12 L20 19" stroke={T.text} strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round" /></svg>
      </div>
      <div style={{ ...btn, width: 56, height: 56, background: T.goldSoft, border: `1px solid ${T.gold}` }}>
        {playing ? (
          <svg width="22" height="22" viewBox="0 0 24 24" fill={T.gold}><rect x="6" y="5" width="4.4" height="14" rx="1.4" /><rect x="13.6" y="5" width="4.4" height="14" rx="1.4" /></svg>
        ) : (
          <svg width="22" height="22" viewBox="0 0 24 24" fill={T.gold}><path d="M8 5 L19 12 L8 19 z" /></svg>
        )}
      </div>
      <div style={btn}>
        <svg width="22" height="22" viewBox="0 0 24 24" fill="none"><path d="M13 5 L20 12 L13 19 M4 5 L11 12 L4 19" stroke={T.text} strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round" /></svg>
      </div>
      <div
        style={{
          marginLeft: 6, padding: "7px 16px", borderRadius: 999, fontSize: 19, fontWeight: 700, fontVariantNumeric: "tabular-nums",
          background: speedActive ? T.goldSoft : "rgba(255,255,255,0.06)",
          border: `1px solid ${speedActive ? T.gold : T.stroke}`,
          color: speedActive ? T.gold : T.dim,
        }}
      >
        {speed}
      </div>
      <div style={{ padding: "7px 16px", borderRadius: 999, fontSize: 19, fontWeight: 700, background: "rgba(255,255,255,0.06)", border: `1px solid ${T.stroke}`, color: T.dim }}>
        ↺ Replay
      </div>
    </div>
  );
};

/**
 * The ambient activity heat map, as ActivityInsightHeatMap renders it in the
 * real app: faint weight-scaled verbs from the focused session's tool
 * activity, floating at fixed anchors around the idle mark.
 */
export const FloatingVerbs: React.FC<{ phrases: { text: string; weight: number; color: string }[] }> = ({ phrases }) => {
  const frame = useCurrentFrame();
  const anchors = [
    { x: 0.5, y: 0.2 }, { x: 0.26, y: 0.32 }, { x: 0.74, y: 0.3 },
    { x: 0.3, y: 0.66 }, { x: 0.7, y: 0.68 }, { x: 0.5, y: 0.79 },
    { x: 0.15, y: 0.49 }, { x: 0.85, y: 0.5 },
  ];
  return (
    <AbsoluteFill style={{ pointerEvents: "none" }}>
      {phrases.slice(0, anchors.length).map((p, i) => {
        const a = anchors[i];
        const pulse = 0.75 + 0.25 * Math.sin(frame / 26 + i * 1.7);
        const size = 17 + p.weight * 17;
        const op = (0.16 + p.weight * 0.36) * pulse;
        return (
          <div
            key={i}
            style={{
              position: "absolute", left: `${a.x * 100}%`, top: `${a.y * 100}%`,
              transform: `translate(-50%, -50%) translateY(${Math.sin(frame / 34 + i * 2.2) * 6}px)`,
              fontSize: size, fontWeight: p.weight > 0.72 ? 700 : 600,
              fontFamily: "ui-rounded, " + T.font,
              color: p.color, opacity: op,
              textShadow: `0 0 ${14 + p.weight * 16}px ${p.color}`,
              whiteSpace: "nowrap",
            }}
          >
            {p.text}
          </div>
        );
      })}
    </AbsoluteFill>
  );
};
