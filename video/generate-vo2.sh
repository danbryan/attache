#!/bin/bash
# Audio for the Promo2 composition: narration (Sekou), in-app sample voices,
# UI/transition sound effects, and a low ambient music bed. Writes clips to
# public/audio2/ and the measured durations back into src/epic/manifest2.json,
# which drives every beat in src/epic/timing2.ts.
#
# Credentials come from the app's own secret store, preferring the unsigned
# dev build's DevelopmentSecrets.json (no keychain prompt) and falling back to
# the unified keychain vault item (com.bryanlabs.attache.secrets /
# unified-vault-v1, which can raise an authorization dialog). Nothing is
# printed. ELEVENLABS_API_KEY in the environment overrides both.
#
# The music bed tries the Eleven Music API first and falls back to a looped
# sound-generation ambient pad if the account has no music access.
#
# GEN limits which sections regenerate (comma-separated out of
# narration,samples,sfx,music); default is all four. Example:
#   GEN=narration,samples ./generate-vo2.sh
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p public/audio2

python3 - <<'EOF'
import json, os, subprocess, sys, urllib.request, urllib.error

AUD = "public/audio2"
MANIFEST = "src/epic/manifest2.json"
SEKOU = "YPtbPhafrxFTDAeaPP4w"
NARRATION_SPEED = 1.1

def stored_key(account):
    dev = os.path.expanduser("~/Library/Application Support/Attache/DevelopmentSecrets.json")
    if os.path.exists(dev):
        value = json.load(open(dev)).get(account)
        if value:
            return value
    blob = subprocess.run(
        ["security", "find-generic-password", "-s", "com.bryanlabs.attache.secrets",
         "-a", "unified-vault-v1", "-w"],
        capture_output=True, text=True, check=True).stdout.strip()
    return json.loads(blob)[account]

EL = os.environ.get("ELEVENLABS_API_KEY") or stored_key("elevenlabs-api-key")

def post(url, body):
    req = urllib.request.Request(url, data=json.dumps(body).encode(), method="POST",
        headers={"xi-api-key": EL, "Content-Type": "application/json"})
    return urllib.request.urlopen(req, timeout=300).read()

def tts(text, voice_id):
    return post(
        f"https://api.elevenlabs.io/v1/text-to-speech/{voice_id}?output_format=mp3_44100_128",
        {"text": text, "model_id": "eleven_multilingual_v2",
         "voice_settings": {"stability": 0.5, "similarity_boost": 0.75}})

def sound(prompt, seconds):
    return post("https://api.elevenlabs.io/v1/sound-generation",
        {"text": prompt, "duration_seconds": max(0.5, min(22, seconds)), "prompt_influence": 0.35})

def save(name, mp3, speed=1.0, lufs=-16):
    raw = f"{AUD}/{name}.raw.wav"
    out = f"{AUD}/{name}.wav"
    open(f"{AUD}/{name}.mp3", "wb").write(mp3)
    subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@44100", f"{AUD}/{name}.mp3", raw], check=True)
    af = f"loudnorm=I={lufs}:TP=-1.5:LRA=11"
    if speed != 1.0:
        af = f"atempo={speed}," + af
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", raw,
                    "-af", af, "-ar", "44100", "-c:a", "pcm_s16le", out], check=True)
    os.remove(f"{AUD}/{name}.mp3"); os.remove(raw)
    return duration(out)

def duration(path):
    info = subprocess.run(["afinfo", path], capture_output=True, text=True).stdout
    return round(float([l for l in info.splitlines() if "estimated duration" in l][0].split()[-2]), 3)

m = json.load(open(MANIFEST))
gen = set((os.environ.get("GEN") or "narration,samples,sfx,music").split(","))

if "narration" in gen:
    for name, seg in m["narration"].items():
        seg["seconds"] = save(name, tts(seg["text"], SEKOU), NARRATION_SPEED)
        print(f"{name}: {seg['seconds']}s")

if "samples" in gen:
    for name, seg in m["samples"].items():
        seg["seconds"] = save(name, tts(seg["text"], seg["voice_id"]))
        print(f"{name} ({seg['voice']}): {seg['seconds']}s")

if "sfx" in gen:
    for name, seg in m["sfx"].items():
        seg["seconds"] = save(name, sound(seg["prompt"], seg["seconds"]), lufs=-20)
        print(f"{name}: {seg['seconds']}s")

if "music" not in gen:
    json.dump(m, open(MANIFEST, "w"), indent=2)
    print("manifest updated")
    sys.exit(0)

# Music bed: Eleven Music, else a looped ambient pad.
bed = m["music"]["bed"]
bed_out = f"{AUD}/music_bed.wav"
try:
    mp3 = post("https://api.elevenlabs.io/v1/music",
               {"prompt": bed["prompt"], "music_length_ms": 120000})
    bed["seconds"] = save("music_bed", mp3, lufs=-24)
    print(f"music_bed (eleven music): {bed['seconds']}s")
except urllib.error.HTTPError as e:
    print(f"eleven music unavailable ({e.code}); falling back to looped ambient pad", file=sys.stderr)
    pad_secs = save("music_pad", sound(
        "warm ambient synth pad, slowly evolving, soft cinematic underscore drone, calm, no melody, seamless", 20),
        lufs=-24)
    # Crossfade the pad against itself into a long seamless bed.
    src = f"{AUD}/music_pad.wav"
    cur = src
    for i in range(3):  # 20s -> ~38 -> ~74 -> ~146
        nxt = f"{AUD}/music_bed_tmp{i}.wav"
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", cur, "-i", cur,
                        "-filter_complex", "acrossfade=d=2:c1=tri:c2=tri", nxt], check=True)
        if cur != src:
            os.remove(cur)
        cur = nxt
    os.replace(cur, bed_out)
    os.remove(src)
    bed["seconds"] = duration(bed_out)
    print(f"music_bed (looped pad): {bed['seconds']}s")

json.dump(m, open(MANIFEST, "w"), indent=2)
print("manifest updated")
EOF
