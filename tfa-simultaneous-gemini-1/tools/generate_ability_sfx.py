"""Generate ability, cast, and weather SFX via the ElevenLabs Sound Effects API.

Reads the API key from the ELEVEN_LABS_API_KEY env var (also accepts
ELEVENLABS_API_KEY as a fallback). Writes mp3 files into ../sfx/.

Usage:
    python tools/generate_ability_sfx.py             # generate only missing files
    python tools/generate_ability_sfx.py --force     # regenerate everything
    python tools/generate_ability_sfx.py --only lightning_strike,heal_chime

Layout:
    SFX_RECIPES groups files into IMPACT, CAST, and WEATHER buckets.
    Each entry has a prompt + duration (seconds, ElevenLabs minimum is 0.5 s).
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

PROMPT_INFLUENCE = 0.55  # slightly lower than footstep generator for more abstract prompts

DRY_TAIL = "close mic, dry mix, no music, no voice"
LOOP_TAIL = "seamless loop, no transient at start or end, ambient bed, no music, no voice"

# ----------------------------------------------------------------------------
# Section A: Impact SFX — played at the resolution/impact location.
# Duration is 1.5 s for most, 2.0 s for vocal/extended sounds.
# ----------------------------------------------------------------------------
IMPACT_RECIPES: dict[str, dict] = {
    # Damage-type impacts
    "lightning_strike": {
        "prompt": f"sharp electric lightning crack with sizzling crackling tail, white-hot zap, {DRY_TAIL}",
        "duration": 1.5,
    },
    "acid_splash": {
        "prompt": f"wet glob of acid splattering on stone, sharp corrosive sizzle and bubbling hiss, {DRY_TAIL}",
        "duration": 1.5,
    },
    "necrotic_drain": {
        "prompt": f"hollow ghostly life-drain, low whispered moan, dark ethereal suction, {DRY_TAIL}",
        "duration": 1.5,
    },
    "sonic_boom": {
        "prompt": f"concussive thunderclap with quick pressure-wave whoosh, deep low-end punch, {DRY_TAIL}",
        "duration": 1.5,
    },
    "force_blast": {
        "prompt": f"dense bass whump with outward shockwave whoosh, kinetic force impact, {DRY_TAIL}",
        "duration": 1.5,
    },
    "ice_storm_impact": {
        "prompt": f"hailstones clattering on ground with sharp ice shards shattering, frozen impact, {DRY_TAIL}",
        "duration": 1.5,
    },
    "poison_cloud": {
        "prompt": f"hissing toxic gas billowing outward, bubbling sickly undertone, gaseous spread, {DRY_TAIL}",
        "duration": 1.5,
    },
    "fire_roar": {
        "prompt": f"sustained roaring flame jet bursting outward, crackling embers, fierce fire whoosh, {DRY_TAIL}",
        "duration": 1.5,
    },

    # Force / control
    "magnetic_pull": {
        "prompt": f"metallic ringing whoosh, iron filings dragged across stone, magnetic attractive hum, {DRY_TAIL}",
        "duration": 1.5,
    },
    "gravity_well": {
        "prompt": f"deep warbling space-warp, low rumble rising in pitch, gravitational distortion, {DRY_TAIL}",
        "duration": 1.5,
    },
    "vortex_wind": {
        "prompt": f"swirling cyclone wind with debris circling, spinning vortex whoosh, {DRY_TAIL}",
        "duration": 1.5,
    },

    # Buff / healing / holy
    "heal_chime": {
        "prompt": f"warm bell shimmer with restorative harp sweep, soft golden glow chime, {DRY_TAIL}",
        "duration": 1.5,
    },
    "holy_cleanse": {
        "prompt": f"clear radiant chord with choir-tinged sparkle, sacred bright cleansing burst, {DRY_TAIL}",
        "duration": 1.5,
    },
    "rage_roar": {
        "prompt": "guttural human battle roar, throat-tearing primal scream, deep furious shout, close mic, dry mix",
        "duration": 2.0,
    },
    "shield_brace": {
        "prompt": f"low metallic hum with shield bracing into stance, grounded defensive thunk, {DRY_TAIL}",
        "duration": 1.5,
    },

    # Charm / mental / fear
    "charm_chime": {
        "prompt": f"sweet glittery harp twinkle with romantic shimmer, magical heart chime, {DRY_TAIL}",
        "duration": 1.5,
    },
    "mental_confuse": {
        "prompt": f"wobbly disoriented warble with dizzy reverb sweep, confused swirl, {DRY_TAIL}",
        "duration": 1.5,
    },
    "fear_shriek": {
        "prompt": "sudden shrill ghostly shriek with nervous heartbeat tail, fearful supernatural cry, close mic, dry mix",
        "duration": 2.0,
    },
    "apathy_wave": {
        "prompt": f"descending sad sigh with dull leaden drone, crushing apathetic wave, {DRY_TAIL}",
        "duration": 1.5,
    },

    # Disease
    "disease_cough": {
        "prompt": "wet sickly cough fit, phlegmy and hoarse, sickened wheeze, close mic, dry mix",
        "duration": 2.0,
    },
    "nausea_retch": {
        "prompt": "dry-heave retch, stomach-turning gurgle, nauseated wet groan, close mic, dry mix",
        "duration": 2.0,
    },

    # Nature
    "animal_call": {
        "prompt": f"mystical wild-animal chorus, distant howls and bird trills, primal nature cry, {DRY_TAIL}",
        "duration": 1.5,
    },
    "nature_bloom": {
        "prompt": f"rapid grass and vines growing, soft earthy unfurling, primal plant bloom, {DRY_TAIL}",
        "duration": 1.5,
    },
}

# ----------------------------------------------------------------------------
# Section B: Cast SFX — played at the caster at start of cast windup.
# Only abilities with cast_time > 0 use these.
# ----------------------------------------------------------------------------
CAST_RECIPES: dict[str, dict] = {
    "arcane_cast": {
        "prompt": f"rising arcane charge hum with magical energy gathering, mystical windup, {DRY_TAIL}",
        "duration": 1.5,
    },
    "holy_cast": {
        "prompt": f"choir-tinged harmonic build, bright sacred chord rising, holy invocation, {DRY_TAIL}",
        "duration": 1.5,
    },
    "necrotic_cast": {
        "prompt": f"dark draining whisper with descending dissonant hum, ominous death magic windup, {DRY_TAIL}",
        "duration": 1.5,
    },
    "nature_cast": {
        "prompt": f"earthy primal rustle with growing root crackle and low woodwind, natural windup, {DRY_TAIL}",
        "duration": 1.5,
    },
    "weather_cast": {
        "prompt": f"rising wind gust with distant thunder, atmospheric weather invocation build, {DRY_TAIL}",
        "duration": 1.5,
    },
    "defensive_cast": {
        "prompt": f"grounded metallic brace with deep settling chord, defensive stance windup, {DRY_TAIL}",
        "duration": 1.5,
    },
}

# ----------------------------------------------------------------------------
# Section C: Weather loops — looped via AudioStreamMP3.loop=true in
# WeatherVFXController. Generated as ~6 s seamless ambient beds.
# ----------------------------------------------------------------------------
WEATHER_RECIPES: dict[str, dict] = {
    "weather_rain_loop": {
        "prompt": f"steady ambient rainfall with soft pitter-patter, distant low rumble, {LOOP_TAIL}",
        "duration": 6.0,
    },
    "weather_acid_rain_loop": {
        "prompt": f"hissing corrosive acid rain with faint bubbling sizzle and ominous tone, {LOOP_TAIL}",
        "duration": 6.0,
    },
    "weather_freezing_rain_loop": {
        "prompt": f"sharp icy hail clatter with cold wind and brittle tinkling, {LOOP_TAIL}",
        "duration": 6.0,
    },
    "weather_snow_loop": {
        "prompt": f"gentle wind through snow, muted soft hush, distant cold air, {LOOP_TAIL}",
        "duration": 6.0,
    },
    "weather_wind_loop": {
        "prompt": f"medium-strength wind whoosh with occasional gust, no debris, {LOOP_TAIL}",
        "duration": 6.0,
    },
}

SFX_RECIPES: dict[str, dict] = {**IMPACT_RECIPES, **CAST_RECIPES, **WEATHER_RECIPES}


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
    parser.add_argument("--force", action="store_true",
                        help="overwrite files that already exist")
    parser.add_argument("--only", default="",
                        help="comma-separated subset of basenames")
    args = parser.parse_args()

    key = os.environ.get("ELEVEN_LABS_API_KEY") or os.environ.get("ELEVENLABS_API_KEY")
    if not key:
        print("ERROR: ELEVEN_LABS_API_KEY not set in environment.", file=sys.stderr)
        return 1

    SFX_DIR.mkdir(parents=True, exist_ok=True)

    selected = SFX_RECIPES
    if args.only:
        wanted = {s.strip() for s in args.only.split(",") if s.strip()}
        selected = {k: v for k, v in SFX_RECIPES.items() if k in wanted}
        if not selected:
            print(f"ERROR: --only matched nothing. Known: {sorted(SFX_RECIPES)}",
                  file=sys.stderr)
            return 1

    failures: list[str] = []
    for basename, recipe in selected.items():
        out_path = SFX_DIR / f"{basename}.mp3"
        if out_path.exists() and not args.force:
            print(f"  skip   {out_path.name} (exists; pass --force to overwrite)")
            continue
        prompt_preview = recipe["prompt"][:60].replace("\n", " ")
        print(f"  gen    {out_path.name}  ({recipe['duration']}s)  \"{prompt_preview}...\"")
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
        print(f"\n{len(failures)} failure(s): {', '.join(failures)}", file=sys.stderr)
        return 2
    print("\nAll done.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
