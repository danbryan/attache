#!/usr/bin/env python3
# Rework the update->personalities beat: reword the two narrations, retarget the
# Concise sample to Adam (deep voice, concise personality), add its announcement.
# Only these 4 clips are (re)generated; every other clip is left untouched.
#   ELEVENLABS_API_KEY=... python3 regen-cmdY.py
import json, os, subprocess, urllib.request

EL = os.environ["ELEVENLABS_API_KEY"]
AUD = "public/audio"
SEKOU = "YPtbPhafrxFTDAeaPP4w"
ADAM = "pNInz6obpgDQGcFmaJgB"
NARRATION_SPEED = 1.1

NARR = {
    "update": "Attaché turns your agents' work into voice memos, in real time. Press Command Y, and pick the one you want to hear.",
    "personalities": "And that same memo, in any personality you choose.",
}
# sample entries: (key, voice, voice_id, text)
SAMPLES = [
    ("vs_concise", "Adam", ADAM, "Your episode's cut into five clips. Captioned and queued to post."),
    ("ann_concise", "Sekou", SEKOU, "Concise."),
]

def el(text, voice_id):
    body = json.dumps({"text": text, "model_id": "eleven_multilingual_v2",
                       "voice_settings": {"stability": 0.5, "similarity_boost": 0.75}}).encode()
    req = urllib.request.Request(
        f"https://api.elevenlabs.io/v1/text-to-speech/{voice_id}?output_format=mp3_44100_128",
        data=body, method="POST", headers={"xi-api-key": EL, "Content-Type": "application/json"})
    return urllib.request.urlopen(req, timeout=120).read()

def save(name, mp3, speed=1.0):
    raw = f"{AUD}/{name}.raw.wav"; out = f"{AUD}/{name}.wav"
    open(f"{AUD}/{name}.mp3", "wb").write(mp3)
    subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@44100", f"{AUD}/{name}.mp3", raw], check=True)
    af = "loudnorm=I=-16:TP=-1.5:LRA=11"
    if speed != 1.0: af = f"atempo={speed}," + af
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", raw, "-af", af,
                    "-ar", "44100", "-c:a", "pcm_s16le", out], check=True)
    os.remove(f"{AUD}/{name}.mp3"); os.remove(raw)
    info = subprocess.run(["afinfo", out], capture_output=True, text=True).stdout
    return round(float([l for l in info.splitlines() if "estimated duration" in l][0].split()[-2]), 3)

vo = json.load(open("src/vo-manifest.json"))
for name, text in NARR.items():
    vo[name]["text"] = text
    vo[name]["seconds"] = save(name, el(text, SEKOU), NARRATION_SPEED)
    print(f"narration {name}: {vo[name]['seconds']}s")
json.dump(vo, open("src/vo-manifest.json", "w"), indent=2)

vs = json.load(open("src/voice-samples.json"))
for key, voice, vid, text in SAMPLES:
    vs[key] = {"voice": voice, "provider": "el", "voice_id": vid, "lang": "en", "text": text}
    vs[key]["seconds"] = save(key, el(text, vid))
    print(f"sample {key} ({voice}): {vs[key]['seconds']}s")
json.dump(vs, open("src/voice-samples.json", "w"), indent=2)
print("done")
