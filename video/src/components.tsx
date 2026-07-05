import React from "react";
import {
  AbsoluteFill,
  interpolate,
  spring,
  useCurrentFrame,
  useVideoConfig,
} from "remotion";
import { T } from "./theme";
import { LOGOS } from "./logos";

/** A monochrome brand mark from logos.ts. */
export const Logo: React.FC<{ name: keyof typeof LOGOS; size?: number; color?: string }> = ({
  name,
  size = 22,
  color = "#F2F2F5",
}) => {
  const logo = LOGOS[name];
  if (!logo) return null;
  return (
    <svg width={size} height={size} viewBox={logo.viewBox} fill={color} style={{ display: "block", flexShrink: 0 }}>
      {logo.paths.map((d, i) => (
        <path key={i} d={d} />
      ))}
    </svg>
  );
};

// Tiled fractal-noise grain, as a data URI. Dithers the gradients (kills the
// visible banding rings on large displays) and gives the dark ground a matte,
// filmic texture.
const GRAIN =
  "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='200' height='200'%3E" +
  "%3Cfilter id='n'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='0.82' numOctaves='2' stitchTiles='stitch'/%3E" +
  "%3C/filter%3E%3Crect width='100%25' height='100%25' filter='url(%23n)'/%3E%3C/svg%3E";

/** Dark stage: soft off-center glows, a filmic grain layer, and a wide vignette. */
export const Stage: React.FC<{ children: React.ReactNode }> = ({ children }) => (
  <AbsoluteFill style={{ backgroundColor: T.bg, fontFamily: T.font }}>
    {/* gentle multi-stop glows — long falloff so there is no hard ring */}
    <AbsoluteFill
      style={{
        background:
          "radial-gradient(1500px 1100px at 66% 26%, rgba(10,132,255,0.06) 0%, rgba(10,132,255,0.022) 30%, transparent 70%)," +
          "radial-gradient(1300px 1000px at 22% 82%, rgba(96,120,168,0.05) 0%, rgba(96,120,168,0.018) 32%, transparent 72%)",
      }}
    />
    {/* faint core lift behind the content */}
    <AbsoluteFill
      style={{ background: "radial-gradient(900px 620px at 50% 48%, rgba(255,255,255,0.022), transparent 68%)" }}
    />
    {children}
    {/* grain */}
    <AbsoluteFill
      style={{ pointerEvents: "none", opacity: 0.05, mixBlendMode: "overlay", backgroundImage: `url("${GRAIN}")`, backgroundSize: "200px 200px" }}
    />
    {/* vignette */}
    <AbsoluteFill
      style={{ pointerEvents: "none", background: "radial-gradient(1700px 1100px at 50% 50%, transparent 52%, rgba(0,0,0,0.55))" }}
    />
  </AbsoluteFill>
);

/** Fade+rise entrance used by nearly everything. */
export const Rise: React.FC<{
  delay?: number;
  children: React.ReactNode;
  style?: React.CSSProperties;
}> = ({ delay = 0, children, style }) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const p = spring({ frame: frame - delay, fps, config: { damping: 200 } });
  return (
    <div style={{ opacity: p, transform: `translateY(${(1 - p) * 26}px)`, ...style }}>
      {children}
    </div>
  );
};

/** The Attaché lockup: rounded A over an equalizer, as in the idle screen. */
export const BrandMark: React.FC<{
  size?: number;
  animate?: boolean;
  color?: string;
  barColor?: (i: number) => string;
}> = ({ size = 220, animate = false, color = "rgba(235,235,240,0.85)", barColor }) => {
  const frame = useCurrentFrame();
  const bars = [0.32, 0.5, 0.68, 0.44, 0.82, 0.6, 0.92, 0.55, 0.75, 0.42, 0.3];
  return (
    <div style={{ width: size, display: "flex", flexDirection: "column", alignItems: "center" }}>
      <div
        style={{
          fontFamily: "ui-rounded, " + T.font,
          fontWeight: 600,
          fontSize: size * 0.62,
          lineHeight: 1,
          color,
          letterSpacing: "-0.02em",
        }}
      >
        A
      </div>
      <div
        style={{
          display: "flex",
          alignItems: "flex-end",
          gap: size * 0.028,
          height: size * 0.26,
          marginTop: -size * 0.05,
        }}
      >
        {bars.map((h, i) => {
          const wave = animate ? 0.62 + 0.38 * Math.sin(frame / 5 + i * 1.1) : 1;
          return (
            <div
              key={i}
              style={{
                width: size * 0.045,
                height: Math.max(size * 0.05, size * 0.26 * h * wave),
                borderRadius: size * 0.03,
                background: barColor
                  ? barColor(i)
                  : `rgba(210,210,218,${0.45 + 0.4 * (i / bars.length)})`,
              }}
            />
          );
        })}
      </div>
    </div>
  );
};

/** macOS-style window chrome around arbitrary content. */
export const MacWindow: React.FC<{
  width: number;
  children: React.ReactNode;
  style?: React.CSSProperties;
}> = ({ width, children, style }) => (
  <div
    style={{
      width,
      borderRadius: 14,
      overflow: "hidden",
      border: `1px solid ${T.stroke}`,
      boxShadow: "0 40px 90px rgba(0,0,0,0.6)",
      background: T.bgPanel,
      ...style,
    }}
  >
    <div style={{ display: "flex", gap: 8, padding: "12px 14px", background: "rgba(255,255,255,0.04)" }}>
      {["#FF5F57", "#FEBC2E", "#28C840"].map((c) => (
        <div key={c} style={{ width: 12, height: 12, borderRadius: 6, background: c, opacity: 0.9 }} />
      ))}
    </div>
    {children}
  </div>
);

/** A physical-looking key cap, optionally "pressed" at a given frame. */
export const KeyCap: React.FC<{ label: string; pressAt?: number; wide?: boolean }> = ({
  label,
  pressAt,
  wide,
}) => {
  const frame = useCurrentFrame();
  const pressed =
    pressAt !== undefined && frame >= pressAt && frame < pressAt + 12;
  return (
    <div
      style={{
        minWidth: wide ? 120 : 84,
        height: 84,
        padding: "0 20px",
        borderRadius: 14,
        display: "flex",
        alignItems: "center",
        justifyContent: "center",
        fontSize: 34,
        fontWeight: 600,
        color: pressed ? T.bg : T.text,
        background: pressed ? T.gold : T.bgRaised,
        border: `1px solid ${pressed ? T.gold : T.stroke}`,
        boxShadow: pressed ? "0 2px 0 rgba(0,0,0,0.4)" : "0 6px 0 rgba(0,0,0,0.4)",
        transform: pressed ? "translateY(4px)" : "none",
        transition: "none",
      }}
    >
      {label}
    </div>
  );
};

/** Karaoke caption line: words light up over [startFrame, endFrame]. */
export const Karaoke: React.FC<{
  text: string;
  startFrame: number;
  endFrame: number;
  fontSize?: number;
}> = ({ text, startFrame, endFrame, fontSize = 44 }) => {
  const frame = useCurrentFrame();
  const words = text.split(" ");
  const per = (endFrame - startFrame) / words.length;
  const active = Math.floor((frame - startFrame) / per);
  return (
    <div
      style={{
        display: "inline-block",
        padding: "22px 34px",
        borderRadius: 18,
        background: "rgba(10,10,14,0.82)",
        border: `1px solid ${T.stroke}`,
        fontSize,
        lineHeight: 1.45,
        fontWeight: 600,
        maxWidth: 1240,
        textAlign: "center",
      }}
    >
      {words.map((w, i) => (
        <span
          key={i}
          style={{
            color: i < active ? T.text : i === active ? T.gold : T.faint,
          }}
        >
          {w}{" "}
        </span>
      ))}
    </div>
  );
};

/** Small gold-accent capsule, e.g. the speed badge. */
export const Capsule: React.FC<{
  children: React.ReactNode;
  active?: boolean;
  fontSize?: number;
}> = ({ children, active, fontSize = 30 }) => (
  <div
    style={{
      padding: "10px 24px",
      borderRadius: 999,
      border: `1px solid ${active ? T.gold : T.stroke}`,
      background: active ? T.goldSoft : "rgba(255,255,255,0.05)",
      color: active ? T.gold : T.dim,
      fontSize,
      fontWeight: 700,
      fontVariantNumeric: "tabular-nums",
    }}
  >
    {children}
  </div>
);

/** Lower-third narration echo, small and unobtrusive. */
export const LowerThird: React.FC<{ children: React.ReactNode }> = ({ children }) => (
  <div
    style={{
      position: "absolute",
      bottom: 64,
      width: "100%",
      display: "flex",
      justifyContent: "center",
    }}
  >
    <div style={{ color: T.dim, fontSize: 30, fontWeight: 500 }}>{children}</div>
  </div>
);

/** Big centered headline. */
export const Headline: React.FC<{ children: React.ReactNode; size?: number; delay?: number }> = ({
  children,
  size = 84,
  delay = 0,
}) => (
  <Rise delay={delay}>
    <div
      style={{
        fontSize: size,
        fontWeight: 700,
        color: T.text,
        textAlign: "center",
        letterSpacing: "-0.02em",
        lineHeight: 1.12,
      }}
    >
      {children}
    </div>
  </Rise>
);

export const fadeInOut = (frame: number, duration: number, edge = 10): number =>
  interpolate(frame, [0, edge, duration - edge, duration], [0, 1, 1, 0], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
  });
