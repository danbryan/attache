#!/bin/bash
# Regenerates every audio clip in public/audio and updates the measured
# durations in src/vo-manifest.json (narration) and src/voice-samples.json
# (the per-personality sample voices). Scene lengths follow those durations.
#
# Narration is one voice (Sekou). The personalities scene and the language
# scene use several voices across two providers, so both keys are needed:
#
#   ELEVENLABS_API_KEY=...  XAI_API_KEY=...  ./generate-vo.sh
#
# Every clip is loudness-normalized to -16 LUFS so the voices sit level.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p public/audio

: "${ELEVENLABS_API_KEY:?set ELEVENLABS_API_KEY}"
: "${XAI_API_KEY:?set XAI_API_KEY}"

python3 - <<'EOF'
import json, os, subprocess, urllib.request

EL = os.environ["ELEVENLABS_API_KEY"]
XAI = os.environ["XAI_API_KEY"]
AUD = "public/audio"

# Narration is always Sekou; sample voice ids live in voice-samples.json.
SEKOU = "YPtbPhafrxFTDAeaPP4w"

def el(text, voice_id):
    body = json.dumps({"text": text, "model_id": "eleven_multilingual_v2",
                       "voice_settings": {"stability": 0.5, "similarity_boost": 0.75}}).encode()
    req = urllib.request.Request(
        f"https://api.elevenlabs.io/v1/text-to-speech/{voice_id}?output_format=mp3_44100_128",
        data=body, method="POST", headers={"xi-api-key": EL, "Content-Type": "application/json"})
    return urllib.request.urlopen(req, timeout=120).read()

def xai(text, voice_id, lang):
    body = json.dumps({"text": text, "voice_id": voice_id, "language": lang,
                       "text_normalization": True,
                       "output_format": {"codec": "mp3", "sample_rate": 44100, "bit_rate": 192000}}).encode()
    req = urllib.request.Request("https://api.x.ai/v1/tts", data=body, method="POST",
        headers={"Authorization": f"Bearer {XAI}", "Content-Type": "application/json"})
    return urllib.request.urlopen(req, timeout=120).read()

def save(name, mp3, speed=1.0):
    raw = f"{AUD}/{name}.raw.wav"
    out = f"{AUD}/{name}.wav"
    open(f"{AUD}/{name}.mp3", "wb").write(mp3)
    subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@44100", f"{AUD}/{name}.mp3", raw], check=True)
    af = "loudnorm=I=-16:TP=-1.5:LRA=11"
    if speed != 1.0:
        af = f"atempo={speed}," + af
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", raw,
                    "-af", af, "-ar", "44100", "-c:a", "pcm_s16le", out], check=True)
    os.remove(f"{AUD}/{name}.mp3"); os.remove(raw)
    info = subprocess.run(["afinfo", out], capture_output=True, text=True).stdout
    return round(float([l for l in info.splitlines() if "estimated duration" in l][0].split()[-2]), 3)

# Narration — all Sekou, nudged 10% faster so the pacing does not drag.
NARRATION_SPEED = 1.1
vo = json.load(open("src/vo-manifest.json"))
for name, seg in vo.items():
    seg["seconds"] = save(name, el(seg["text"], SEKOU), NARRATION_SPEED)
    print(f"{name}: {seg['seconds']}s")
json.dump(vo, open("src/vo-manifest.json", "w"), indent=2)

# Sample voices — mixed providers; each entry names its voice + voice_id.
vs = json.load(open("src/voice-samples.json"))
for name, s in vs.items():
    if s["provider"] == "el":
        audio = el(s["text"], s["voice_id"])
    else:
        audio = xai(s["text"], s["voice_id"], s["lang"])
    s["seconds"] = save(name, audio)
    print(f"{name} ({s['voice']}): {s['seconds']}s")
json.dump(vs, open("src/voice-samples.json", "w"), indent=2)
EOF
