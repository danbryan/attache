#!/usr/bin/env python3
# Fix the voices to the approved set: the memo (⌘Y) -> Hope, the sharp editor ->
# Jessica, the hype coach -> Titan. Text is unchanged; only the voice differs.
#   ELEVENLABS_API_KEY=... python3 regen-voices.py
import json, os, subprocess, urllib.request

EL = os.environ["ELEVENLABS_API_KEY"]
AUD = "public/audio"

# (key, voice label, voice_id, text, stability)
CLIPS = [
    ("vs_concise", "Hope", "WAhoMTNdLdMoq1j3wf3I",
     "Your episode's cut into five clips. Captioned and queued to post.", 0.5),
    ("vs_editor", "Jessica", "yj30vwTGJxSHezdAGsv9",
     "Five clips, captioned and queued. But clip two's hook is weak. Want me to recut it?", 0.4),
    ("vs_hype", "Titan", "dtSEyYGNJqjrtBArPCVZ",
     "High five on those clips! That's a week of content before lunch. Let's go!", 0.35),
]

def el(text, voice_id, stability):
    body = json.dumps({"text": text, "model_id": "eleven_multilingual_v2",
                       "voice_settings": {"stability": stability, "similarity_boost": 0.75}}).encode()
    req = urllib.request.Request(
        f"https://api.elevenlabs.io/v1/text-to-speech/{voice_id}?output_format=mp3_44100_128",
        data=body, method="POST", headers={"xi-api-key": EL, "Content-Type": "application/json"})
    return urllib.request.urlopen(req, timeout=120).read()

def save(name, mp3):
    raw = f"{AUD}/{name}.raw.wav"; out = f"{AUD}/{name}.wav"
    open(f"{AUD}/{name}.mp3", "wb").write(mp3)
    subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@44100", f"{AUD}/{name}.mp3", raw], check=True)
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", raw,
                    "-af", "loudnorm=I=-16:TP=-1.5:LRA=11", "-ar", "44100", "-c:a", "pcm_s16le", out], check=True)
    os.remove(f"{AUD}/{name}.mp3"); os.remove(raw)
    info = subprocess.run(["afinfo", out], capture_output=True, text=True).stdout
    return round(float([l for l in info.splitlines() if "estimated duration" in l][0].split()[-2]), 3)

vs = json.load(open("src/voice-samples.json"))
for key, voice, vid, text, stab in CLIPS:
    vs[key] = {"voice": voice, "provider": "el", "voice_id": vid, "lang": "en", "text": text}
    vs[key]["seconds"] = save(key, el(text, vid, stab))
    print(f"{key} ({voice}): {vs[key]['seconds']}s")
json.dump(vs, open("src/voice-samples.json", "w"), indent=2)
print("done")
