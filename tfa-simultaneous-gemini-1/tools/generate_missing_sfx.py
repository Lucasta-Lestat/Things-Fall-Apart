"""Regenerate the ElevenLabs-sourced SFX from the 2026-11 missing-sounds pass.

Reads the API key from the ELEVEN_LABS_API_KEY env var (also accepts
ELEVENLABS_API_KEY as a fallback). Writes into ../sfx/: .mp3 for one-shots,
.ogg for loops (see below).

Usage:
    python tools/generate_missing_sfx.py             # generate only missing files
    python tools/generate_missing_sfx.py --force     # regenerate everything
    python tools/generate_missing_sfx.py --only quest_start,amb_town_loop

Layout:
    SFX_RECIPES groups files into UI, STINGER, COMBAT, VOCAL, WORLD and LOOP
    buckets. Each entry is the exact request behind the shipped file: prompt,
    duration (seconds, ElevenLabs minimum is 0.5 s) and prompt_influence, all
    on model eleven_text_to_sound_v2. Optional keys:
      loop    -- request a seamless loop (loop=true). The response is
                 transcoded to Ogg Vorbis with ffmpeg, because MP3 encoder
                 padding leaves a gap at the loop point. Without ffmpeg the
                 .mp3 is written instead, with a warning.
      layers  -- extra takes the shipped file was mixed from. They are written
                 to tools/sfx_layers/ (Godot-ignored) for manual mixing.
      note    -- a hand edit the shipped file has that a fresh take won't.

    Only the ElevenLabs-generated sounds are here. The Kenney, OpenGameArt and
    derived sounds from the same pass are listed in SFX_CREDITS.md.

A regenerated file is a NEW raw take, not the shipped audio. The shipped files
were also trimmed, faded and loudness-normalised to their category's level
(UI -20, stingers -22.5, combat -16, vocal -16, world -16 LUFS; loops -25.6
and ambience beds -31.6 LUFS integrated; true peak <= -1 dBTP). See
SFX_CREDITS.md. Re-level a fresh take before it ships.
"""

from __future__ import annotations
import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
import urllib.request
import urllib.error
from pathlib import Path

API_URL = "https://api.elevenlabs.io/v1/sound-generation"
MODEL_ID = "eleven_text_to_sound_v2"
SFX_DIR = Path(__file__).resolve().parent.parent / "sfx"
LAYER_DIR = Path(__file__).resolve().parent / "sfx_layers"

PROMPT_INFLUENCE = 0.55  # fallback only; every recipe below sets its own

# ----------------------------------------------------------------------------
# Section A: UI foley -- UI bus, played with SfxManager.play_ui().
# ----------------------------------------------------------------------------
UI_RECIPES: dict[str, dict] = {
    "stamp": {
        "prompt": "heavy rubber ink stamp thumped once onto a paper identity card lying on a "
                  "thick wooden desk, single solid thud with a slight paper slap, close mic, dry "
                  "mix, no music, no voice",
        "duration": 0.5,
        "prompt_influence": 0.6,
    },
    "stealth_on": {
        "prompt": "a soft breathy whispered shh hush, a person quietly signalling silence, faint "
                  "rustle of a wool cloak, close mic, dry recording, no music, no words",
        "duration": 0.6,
        "prompt_influence": 0.55,
    },
    "stealth_off": {
        "prompt": "gentle clothing rustle as someone stands up, light leather creak, close mic, "
                  "dry mix, no music, no voice",
        "duration": 0.6,
        "prompt_influence": 0.55,
    },
}

# ----------------------------------------------------------------------------
# Section B: Musical stingers -- period acoustic instruments only (lute, harp, viol,
# natural trumpet, bells); never synths or orchestral-hollywood.
# ----------------------------------------------------------------------------
STINGER_RECIPES: dict[str, dict] = {
    "quest_start": {
        "prompt": "ascending four-note plucked lute motif, slow and clear, notes climbing step by "
                  "step upward, final note rings out and fades naturally, warm wooden period "
                  "instrument, hopeful start of an adventure, solo instrument, no vocals, no "
                  "percussion",
        "duration": 1.8,
        "prompt_influence": 0.65,
    },
    "quest_advance": {
        "prompt": "two quick light plucked notes on a solo Renaissance lute, the second note one "
                  "step higher, brief and soft, dry close mic, tiny musical cue, no vocals, no "
                  "other instruments",
        "duration": 1.0,
        "prompt_influence": 0.6,
    },
    "quest_complete": {
        "prompt": "brief victorious courtly fanfare, a valveless natural trumpet plays a rising "
                  "three-note call over plucked lute, ending on a held ringing major triad, "
                  "period instruments, short musical sting, no vocals, no drums",
        "duration": 2.5,
        "prompt_influence": 0.6,
    },
    "quest_fail": {
        "prompt": "solo low bass viol playing a slow descending minor phrase of four notes, a "
                  "soft plucked lute chord underneath, somber resigned late-Renaissance lament, "
                  "quest failed cue, short musical sting, no vocals, no drums, close mic, dry mix",
        "duration": 2.0,
        "prompt_influence": 0.6,
    },
    "favor_down": {
        "prompt": "solo lute, two somber plucked bass notes falling downward, muted palm-damped "
                  "strings, quiet disappointment, short musical sting, no vocals, no drums",
        "duration": 0.8,
        "prompt_influence": 0.6,
        "note": "shipped file is a two-note edit of this take (D3 then C3, 2.2 kHz low-pass)",
    },
    "crime_sting": {
        "prompt": "low dark bowed strings, a quick tense dissonant tremolo that swells and is cut "
                  "off abruptly, guilt and menace, small viol consort, short musical sting, no "
                  "vocals, no drums, dry recording",
        "duration": 1.5,
        "prompt_influence": 0.6,
    },
    "party_join": {
        "prompt": "harp and lute play a short ascending phrase that settles on a warm major "
                  "chord, hopeful companionship, Renaissance period instruments, short musical "
                  "sting, no vocals, no drums",
        "duration": 1.5,
        "prompt_influence": 0.6,
    },
    "party_leave": {
        "prompt": "sad solo lute melody falling downward: four slow plucked notes, each one lower "
                  "than the last, gentle and wistful, ending on the lowest note left ringing, "
                  "solo lute only, no vocals, no drums, close mic, dry mix",
        "duration": 1.5,
        "prompt_influence": 0.7,
    },
    "ability_learned": {
        "prompt": "renaissance harp and plucked lute, quick ascending major arpeggio resolving on "
                  "a bright ringing chord with a gentle sparkling shimmer, short musical sting, "
                  "no vocals, no drums",
        "duration": 1.5,
        "prompt_influence": 0.5,
    },
    "vow_broken": {
        "prompt": "a sacred oath shattering, a damaged bronze chapel bell gives one detuned "
                  "rattling strike over a low ominous bowed viol drone that fades into darkness, "
                  "short musical sting, no vocals, no drums",
        "duration": 1.5,
        "prompt_influence": 0.55,
    },
    "stress_affliction": {
        "prompt": "horror sting: a loud pounding heartbeat thumping four times and speeding up, "
                  "lub-dub lub-dub lub-dub lub-dub, while a dissonant low bowed cello and viol "
                  "cluster grows steadily louder underneath into a harsh crescendo, panic and "
                  "dread, no melody, no vocals, close mic, dry mix",
        "duration": 2.0,
        "prompt_influence": 0.65,
        "layers": [
            {
                "prompt": "low dissonant bowed cello and viol cluster crescendo, a tense string swell "
                          "rising from near silence to a loud harsh peak, horror film strings, sustained "
                          "tremolo, no percussion, no melody, no vocals, close mic, dry mix",
                "duration": 2.0,
                "prompt_influence": 0.7,
            },
        ],
        "note": "shipped file = heartbeat take + the layer at half speed (-8 dB) and a semitone above that (-14 dB)",
    },
    "stress_virtue": {
        "prompt": "natural trumpet and sackbut swelling upward into a noble major chord over a "
                  "sustained wordless choir 'ah', steadfast resolve, short musical sting, no "
                  "lyrics, no drums",
        "duration": 2.0,
        "prompt_influence": 0.55,
        "note": "shipped file adds a -14 dB -> 0 dB crescendo over the first 0.85 s",
    },
    "alert_spotted": {
        "prompt": "short sharp staccato string stab, viol consort striking a tense dissonant "
                  "chord, sudden alarm, short musical sting, no vocals, no drums",
        "duration": 0.7,
        "prompt_influence": 0.65,
    },
    "alert_search": {
        "prompt": "a pizzicato viol plucks two quiet notes, a low note then a higher one, an "
                  "uncertain questioning hmm, sparse and light, short musical sting, no vocals, "
                  "no drums",
        "duration": 0.7,
        "prompt_influence": 0.6,
        "note": "shipped file is a two-note edit of this take (first 0.16 s, then the take +5 semitones)",
    },
}

# ----------------------------------------------------------------------------
# Section C: Combat -- wounds and gore.
# ----------------------------------------------------------------------------
COMBAT_RECIPES: dict[str, dict] = {
    "bleed": {
        "prompt": "short wet flesh tear with a squelch and a quick spatter of blood droplets on "
                  "stone, gory wound, close mic, dry mix, no music, no voice",
        "duration": 0.6,
        "prompt_influence": 0.6,
    },
    "bleed_drip": {
        "prompt": "thick liquid drips falling into a small puddle, two or three drops, close mic, "
                  "dry mix, no music, no voice",
        "duration": 0.6,
        "prompt_influence": 0.55,
    },
    "drink_1": {
        "prompt": "a person drinking water from a leather flask, three wet gulping swallows, "
                  "close mic, dry recording, no music, no words",
        "duration": 1.0,
        "prompt_influence": 0.55,
    },
    "gore": {
        "prompt": "wet flesh tearing with a sharp bone crack, limb severed, gory squelch, close "
                  "mic, dry mix, no music, no voice",
        "duration": 0.8,
        "prompt_influence": 0.6,
    },
}

# ----------------------------------------------------------------------------
# Section D: Vocal -- creature deaths and choking. No words.
# ----------------------------------------------------------------------------
VOCAL_RECIPES: dict[str, dict] = {
    "beast_death_1": {
        "prompt": "wounded wild dog's last cry, high strained yelp then a trembling whimper "
                  "trailing off into a final breath, animal only, close mic, dry recording, no "
                  "music, no words",
        "duration": 1.5,
        "prompt_influence": 0.55,
    },
    "beast_death_2": {
        "prompt": "wild beast collapsing, a guttural agonized squeal-grunt, then labored choking "
                  "breaths fading to nothing, animal only, close mic, dry recording, no music, no "
                  "words",
        "duration": 1.5,
        "prompt_influence": 0.55,
    },
    "monster_death": {
        "prompt": "large grotesque creature's death throes, a deep throaty bellow that breaks "
                  "into wet bubbling gurgles and a slow fading exhale, non-human, close mic, dry "
                  "recording, no music, no words",
        "duration": 2.0,
        "prompt_influence": 0.55,
    },
    "undead_death": {
        "prompt": "brittle ancient bones crumbling apart and rattling to the ground, a skull "
                  "clunks, a cold hollow wind-like sigh dissipating into nothing, close mic, dry "
                  "recording, no music, no words",
        "duration": 1.5,
        "prompt_influence": 0.5,
        "layers": [
            {
                "prompt": "a single long hollow ghostly exhale, a cold breathy whisper of air dissipating "
                          "into silence, eerie, sound effect, close mic, no music, no words",
                "duration": 1.2,
                "prompt_influence": 0.6,
            },
        ],
        "note": "shipped file = bone clatter 0-0.75 s with the exhale layer entering at 0.38 s (-12 dB peak)",
    },
    "gasp": {
        "prompt": "an adult man suffocating, a strained choking gasp for air through a "
                  "constricted throat, desperate wheezing inhale, close mic, dry recording, no "
                  "music, no words",
        "duration": 1.0,
        "prompt_influence": 0.6,
    },
}

# ----------------------------------------------------------------------------
# Section E: World one-shots -- bells, fire, spell and gadget effects.
# ----------------------------------------------------------------------------
WORLD_RECIPES: dict[str, dict] = {
    "alarm_bell": {
        "prompt": "heavy iron town alarm bell clanging rapidly and urgently, hand-rung bell "
                  "struck fast over and over to rouse the watch, harsh metallic clangs, close "
                  "mic, dry mix, no music, no voice",
        "duration": 2.5,
        "prompt_influence": 0.6,
    },
    "church_bell": {
        "prompt": "One deep church bell toll from a distant stone bell tower, a single heavy "
                  "clang with rich metallic overtones that rings out and slowly decays, outdoors, "
                  "faint air. One strike only.",
        "duration": 5.0,
        "prompt_influence": 0.5,
    },
    "fire_ignite": {
        "prompt": "Fire igniting: a soft low whoomp as flames catch on dry wood, then a brief "
                  "crackle of burning wood fading out, short sound effect.",
        "duration": 0.8,
        "prompt_influence": 0.6,
    },
    "fizzle": {
        "prompt": "magic spell fizzling out, crackling sparks sputtering and dying with a soft "
                  "deflating puff of air, failed enchantment, close mic, dry mix, no music, no "
                  "voice",
        "duration": 0.8,
        "prompt_influence": 0.55,
    },
    "electric_jolt": {
        "prompt": "Quick small electric shock zap: a brief buzzing spark discharge with crackle "
                  "from a little hand-held shock device, very short. Sound effect only, no music.",
        "duration": 0.5,
        "prompt_influence": 0.5,
        "note": "shipped file is the first 0.36 s of this take",
    },
    "ink_splat": {
        "prompt": "thick black ink flung from an inkwell slapping wetly onto paper and skin, "
                  "short liquid splash, close mic, dry mix, no music, no voice",
        "duration": 0.5,
        "prompt_influence": 0.6,
    },
    "smoke_hiss": {
        "prompt": "clay smoke grenade cracking open on the ground, a sustained gassy whooshing "
                  "hiss of dense smoke pouring out and fading, close mic, dry mix, no music, no "
                  "voice",
        "duration": 1.2,
        "prompt_influence": 0.55,
    },
    "march_drum": {
        "prompt": "Renaissance soldiers' rope-tensioned side drum beating two bars of a steady "
                  "march rhythm, clear separate strikes with crisp snare rattle at walking tempo, "
                  "rallying order to march, solo drum only, dry recording, no voice",
        "duration": 2.0,
        "prompt_influence": 0.65,
    },
    "hush": {
        "prompt": "magical silence falling, a reverse whoosh sucking all sound inward into "
                  "muffled stillness, air pressure drop, close mic, dry mix, no music, no voice",
        "duration": 1.0,
        "prompt_influence": 0.55,
    },
}

# ----------------------------------------------------------------------------
# Section F: Loops -- requested with loop=true and written as .ogg (Vorbis has no MP3
# encoder padding, so the loop point is gapless). fire/swarm/oil are positional
# SFX loops; amb_* are the per-map ambience beds.
# ----------------------------------------------------------------------------
LOOP_RECIPES: dict[str, dict] = {
    "fire_crackle_loop": {
        "prompt": "Burning timber fire crackling and popping, steady stream of small crisp "
                  "crackles and occasional louder ember pops, warm gentle flame bed, even level "
                  "throughout, seamless loop.",
        "duration": 8.0,
        "prompt_influence": 0.6,
        "loop": True,
    },
    "swarm_skitter_loop": {
        "prompt": "a swarm of rats skittering and scratching across stone cobbles, many tiny "
                  "claws, occasional squeaks, seamless loop, steady ambient bed, no music",
        "duration": 6.0,
        "prompt_influence": 0.5,
        "loop": True,
        "note": "shipped file crossfades its last 0.5 s into the head (5.5 s loop)",
    },
    "oil_gush_loop": {
        "prompt": "thick black crude oil gushing up from a hole in the ground, viscous glugging "
                  "and bubbling, heavy slow liquid gurgle, seamless loop, steady ambient bed, no "
                  "music, no voice",
        "duration": 6.0,
        "prompt_influence": 0.55,
        "loop": True,
        "layers": [
            {
                "prompt": "viscous tar-like liquid welling up into a pool, thick sludgy bubbles bursting "
                          "with wet bloops, continuous slow glug, seamless loop, steady ambient bed, no "
                          "music, no voice",
                "duration": 6.0,
                "prompt_influence": 0.55,
                "loop": True,
            },
        ],
        "note": "shipped file = sample-aligned sum of both loop takes, layer at -2 dB",
    },
    "amb_town_loop": {
        "prompt": "outdoor market square walla, faint crowd chatter, cart wheels on cobbles, "
                  "church square atmosphere, seamless loop, steady ambient bed, no music",
        "duration": 22.0,
        "prompt_influence": 0.55,
        "loop": True,
    },
    "amb_tavern_loop": {
        "prompt": "pub crowd walla, indistinct chatter of dozens of patrons, occasional glass "
                  "clink, seamless loop, steady ambient bed, no music",
        "duration": 22.0,
        "prompt_influence": 0.55,
        "loop": True,
    },
    "amb_cemetery_loop": {
        "prompt": "lonely cemetery at dusk ambience, cold wind blowing softly through long grass "
                  "and bare trees, dry leaves rustling, one crow cawing far away, faint creak of "
                  "an old iron gate, quiet and eerie, natural outdoor field recording, seamless "
                  "ambient loop, no music, no voices",
        "duration": 20.0,
        "prompt_influence": 0.5,
        "loop": True,
    },
    "amb_countryside_loop": {
        "prompt": "warm summer hillside in the Italian countryside: blackbirds, finches and "
                  "sparrows singing among olive trees, a quiet bed of cicadas and crickets, "
                  "gentle wind, open rural nature soundscape, field recording, seamless loop, no "
                  "music, no people",
        "duration": 20.0,
        "prompt_influence": 0.6,
        "loop": True,
    },
}

SFX_RECIPES: dict[str, dict] = {
    **UI_RECIPES, **STINGER_RECIPES, **COMBAT_RECIPES,
    **VOCAL_RECIPES, **WORLD_RECIPES, **LOOP_RECIPES,
}


def generate(api_key: str, prompt: str, duration: float, prompt_influence: float,
             loop: bool = False) -> bytes:
    body = {
        "text": prompt,
        "duration_seconds": duration,
        "prompt_influence": prompt_influence,
        "model_id": MODEL_ID,
    }
    if loop:
        body["loop"] = True
    payload = json.dumps(body).encode("utf-8")
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


def find_ffmpeg() -> str | None:
    """ffmpeg from $FFMPEG, then PATH, then the imageio-ffmpeg wheel if installed."""
    env = os.environ.get("FFMPEG")
    if env and Path(env).is_file():
        return env
    found = shutil.which("ffmpeg")
    if found:
        return found
    try:
        import imageio_ffmpeg  # type: ignore
        return imageio_ffmpeg.get_ffmpeg_exe()
    except Exception:  # noqa: BLE001
        return None


def write_ogg(ffmpeg: str, mp3_bytes: bytes, out_path: Path) -> None:
    with tempfile.TemporaryDirectory() as tmp:
        src = Path(tmp) / "take.mp3"
        src.write_bytes(mp3_bytes)
        subprocess.run(
            [ffmpeg, "-v", "error", "-y", "-i", str(src),
             "-c:a", "libvorbis", "-q:a", "5", str(out_path)],
            check=True,
        )


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

    ffmpeg = find_ffmpeg() if any(r.get("loop") for r in selected.values()) else None

    failures: list[str] = []
    for basename, recipe in selected.items():
        loop = bool(recipe.get("loop"))
        as_ogg = loop and ffmpeg is not None
        out_path = SFX_DIR / f"{basename}{'.ogg' if as_ogg else '.mp3'}"
        # A loop already shipped as .ogg must not gain an .mp3 twin (SfxManager
        # keys sounds by basename, so the two would shadow each other).
        twins = [SFX_DIR / f"{basename}.ogg", SFX_DIR / f"{basename}.mp3"] if loop else [out_path]
        existing = [p for p in twins if p.exists()]
        if existing and not args.force:
            print(f"  skip   {existing[0].name} (exists; pass --force to overwrite)")
            continue
        if loop and not as_ogg:
            print(f"  WARN   {basename}: ffmpeg not found, writing .mp3 -- MP3 padding "
                  f"leaves a gap at the loop point. Install ffmpeg (or set FFMPEG) for .ogg.",
                  file=sys.stderr)
        for twin in existing:
            if twin != out_path:
                print(f"  WARN   {twin.name} also exists; delete one so they don't shadow "
                      f"each other.", file=sys.stderr)

        takes = [(out_path, recipe)]
        for i, layer in enumerate(recipe.get("layers", []), start=1):
            takes.append((LAYER_DIR / f"{basename}__layer{i}.mp3", layer))

        for path, take in takes:
            influence = take.get("prompt_influence", PROMPT_INFLUENCE)
            take_loop = bool(take.get("loop", loop if path == out_path else False))
            prompt_preview = take["prompt"][:60].replace("\n", " ")
            print(f"  gen    {path.name}  ({take['duration']}s{', loop' if take_loop else ''})"
                  f"  \"{prompt_preview}...\"")
            try:
                audio = generate(key, take["prompt"], take["duration"], influence, take_loop)
            except urllib.error.HTTPError as e:
                body = e.read().decode("utf-8", errors="replace")[:500]
                print(f"  FAIL   {path.name}  HTTP {e.code}: {body}", file=sys.stderr)
                failures.append(path.stem)
                continue
            except Exception as e:  # noqa: BLE001
                print(f"  FAIL   {path.name}  {type(e).__name__}: {e}", file=sys.stderr)
                failures.append(path.stem)
                continue
            if path.parent == LAYER_DIR:
                LAYER_DIR.mkdir(parents=True, exist_ok=True)
                (LAYER_DIR / ".gdignore").touch()  # raw layers are not game assets
            if path.suffix == ".ogg":
                try:
                    write_ogg(ffmpeg, audio, path)
                except (OSError, subprocess.CalledProcessError) as e:
                    print(f"  FAIL   {path.name}  ffmpeg: {e}", file=sys.stderr)
                    failures.append(path.stem)
                    continue
                print(f"  ok     {path.name}  ({path.stat().st_size:,} bytes, Ogg Vorbis)")
            else:
                path.write_bytes(audio)
                print(f"  ok     {path.name}  ({len(audio):,} bytes)")
        if recipe.get("layers"):
            print(f"  note   {basename}: shipped file is a mix of {len(takes)} takes; layers "
                  f"are in {LAYER_DIR.name}/ ({recipe.get('note', 'see SFX_CREDITS.md')})")
        elif recipe.get("note"):
            print(f"  note   {basename}: {recipe['note']}")

    if failures:
        print(f"\n{len(failures)} failure(s): {', '.join(failures)}", file=sys.stderr)
        return 2
    print("\nAll done.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
