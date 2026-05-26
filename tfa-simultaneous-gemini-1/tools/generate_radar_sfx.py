"""Generate the radar/sonar 'first contact' ping SFX via ElevenLabs.

Single recipe: a short, soft sonar blip played at low volume when the player
hears an enemy they have never directly seen. Designed for dread, not
spectacle.

Reads ELEVEN_LABS_API_KEY (or ELEVENLABS_API_KEY) from env. Writes to
../sfx/radar_ping.mp3.

Usage:
    python tools/generate_radar_sfx.py
    python tools/generate_radar_sfx.py --force
"""

from __future__ import annotations
import argparse
import json
import os
import sys
import urllib.request
import urllib.error
from pathlib import Path

API_URL = "https://api.elevenlabs.io/v1/sound-generation"
SFX_DIR = Path(__file__).resolve().parent.parent / "sfx"

PROMPT_INFLUENCE = 0.65

RADAR_RECIPES: dict[str, dict] = {
    "radar_ping": {
        "prompt": (
            "single soft submarine sonar ping, gentle high-pitched bell-like "
            "blip with brief watery reverb tail, quiet and subtle, sense of "
            "unease, close mic, dry, no music, no voice"
        ),
        "duration": 1.0,
    },
}


def generate(api_key: str, prompt: str, duration: float) -> bytes:
    payload = json.dumps({
        "text": prompt,
        "duration_seconds": duration,
        "prompt_influence": PROMPT_INFLUENCE,
    }).encode("utf-8")
    req = urllib.request.Request(
        API_URL,
        data=payload,
        headers={
            "xi-api-key": api_key,
            "Content-Type": "application/json",
            "Accept": "audio/mpeg",
        },
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=180) as resp:
        return resp.read()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args()

    key = os.environ.get("ELEVEN_LABS_API_KEY") or os.environ.get("ELEVENLABS_API_KEY")
    if not key:
        print("ERROR: ELEVEN_LABS_API_KEY not set in environment.", file=sys.stderr)
        return 1

    SFX_DIR.mkdir(parents=True, exist_ok=True)

    failures: list[str] = []
    for basename, recipe in RADAR_RECIPES.items():
        out_path = SFX_DIR / f"{basename}.mp3"
        if out_path.exists() and not args.force:
            print(f"  skip   {out_path.name} (exists; pass --force to overwrite)")
            continue
        print(f"  gen    {out_path.name}  ({recipe['duration']}s)")
        try:
            audio = generate(key, recipe["prompt"], recipe["duration"])
        except urllib.error.HTTPError as e:
            body = e.read().decode("utf-8", errors="replace")[:500]
            print(f"  FAIL   {out_path.name}  HTTP {e.code}: {body}", file=sys.stderr)
            failures.append(basename)
            continue
        except Exception as e:  # noqa: BLE001
            print(f"  FAIL   {out_path.name}  {type(e).__name__}: {e}", file=sys.stderr)
            failures.append(basename)
            continue
        out_path.write_bytes(audio)
        print(f"  ok     {out_path.name}  ({len(audio):,} bytes)")

    if failures:
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
