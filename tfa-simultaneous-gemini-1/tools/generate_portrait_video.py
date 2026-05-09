#!/usr/bin/env python3
"""Generate a short looping speaking-portrait video clip via Veo (Gemini API).

This is a prototype/comparison piece for the sprite-frame animation pipeline
(see generate_portrait_animations.py). It uses an existing portrait PNG as the
seed image and asks Veo to produce a few seconds of subtle speaking motion
that loops. Output is an MP4 alongside an OGV converted via ffmpeg (Godot's
built-in VideoStreamPlayer only supports Theora/.ogv natively).

Usage:
    python tools/generate_portrait_video.py [--id jacana]
                                             [--model veo-3.0-fast-generate-preview]
                                             [--duration 4]
                                             [--no-ogv]

Requires GEMINI_API_KEY (or GOOGLE_API_KEY), google-genai, and ffmpeg on PATH
(unless --no-ogv).
"""

import argparse
import shutil
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from generate_character_icons import ICONS_DIR, init_client  # noqa: E402

ANIM_DIR = ICONS_DIR / "anim"
DEFAULT_MODEL = "veo-3.1-fast-generate-preview"


def build_prompt(char_id: str) -> str:
    pretty = char_id.replace("_", " ")
    return (
        f"A stylized 1980s AD&D-style fantasy character portrait of {pretty}, "
        "head and shoulders, painterly with halftone newsprint grain. "
        "The character is talking animatedly with subtle natural head bobs, "
        "occasional blinks, and the mouth opens and closes naturally as if "
        "speaking. The background and lighting stay completely static and "
        "match the reference image exactly. No camera movement, no zoom, no "
        "scene changes. Loops seamlessly from end back to start."
    )


def parse_args():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--id", default="jacana", help="Character id (default: jacana)")
    p.add_argument("--model", default=DEFAULT_MODEL,
                   help=f"Veo model id. Default {DEFAULT_MODEL}.")
    p.add_argument("--duration", type=int, default=4,
                   help="Video duration in seconds (default 4).")
    p.add_argument("--no-ogv", action="store_true",
                   help="Skip ffmpeg conversion to .ogv (just save the .mp4).")
    p.add_argument("--dry-run", action="store_true",
                   help="Print prompt and target paths only.")
    return p.parse_args()


def main():
    args = parse_args()
    char_id = args.id
    src = ICONS_DIR / f"{char_id}_icon.png"
    if not src.exists():
        sys.exit(f"ERROR: portrait missing at {src}")

    out_dir = ANIM_DIR / char_id
    out_dir.mkdir(parents=True, exist_ok=True)
    mp4_path = out_dir / "speak.mp4"
    ogv_path = out_dir / "speak.ogv"

    prompt = build_prompt(char_id)
    print(f"Model:   {args.model}")
    print(f"Source:  {src}")
    print(f"Output:  {mp4_path}")
    print(f"Prompt:  {prompt}")
    if args.dry_run:
        return

    client = init_client()
    from google.genai import types  # type: ignore

    print("Submitting Veo job (this can take a couple minutes)...")
    image_part = types.Image(image_bytes=src.read_bytes(), mime_type="image/png")
    # Veo only supports 16:9 / 9:16 aspect ratios. We use 9:16 (vertical) since
    # the source is a head-and-shoulders bust; the output is center-cropped to
    # square in the ffmpeg step below to match the original portrait shape.
    operation = client.models.generate_videos(
        model=args.model,
        prompt=prompt,
        image=image_part,
        config=types.GenerateVideosConfig(
            aspect_ratio="9:16",
            number_of_videos=1,
        ),
    )

    # Poll until the long-running operation finishes.
    while not getattr(operation, "done", False):
        time.sleep(10)
        operation = client.operations.get(operation)
        print(f"  ...status: done={getattr(operation, 'done', False)}")

    response = getattr(operation, "response", None) or getattr(operation, "result", None)
    videos = getattr(response, "generated_videos", None) if response else None
    if not videos:
        sys.exit("ERROR: Veo returned no videos. Inspect the operation object manually.")

    video = videos[0]
    # SDK shape varies by version: some expose .video.video_bytes, some require
    # an explicit download via client.files.download(file=...).
    raw: bytes | None = None
    if hasattr(video, "video") and getattr(video.video, "video_bytes", None):
        raw = video.video.video_bytes
    elif hasattr(video, "video"):
        try:
            client.files.download(file=video.video)
            raw = video.video.video_bytes
        except Exception as e:
            sys.exit(f"ERROR: failed to download video bytes: {e}")
    if not raw:
        sys.exit("ERROR: could not extract video bytes from Veo response.")

    mp4_path.write_bytes(raw)
    print(f"Saved {mp4_path} ({len(raw)} bytes)")

    if args.no_ogv:
        return
    if not shutil.which("ffmpeg"):
        print("WARNING: ffmpeg not on PATH; skipping .ogv conversion. "
              "Install ffmpeg or pass --no-ogv to silence this.")
        return
    print(f"Converting to {ogv_path} (center-cropped to square)...")
    # Veo outputs 9:16; center-crop to square (height x height starting at the
    # horizontal center) to match the original 1:1 portrait shape, then encode
    # to Theora for Godot's built-in VideoStreamPlayer.
    subprocess.run(
        ["ffmpeg", "-y", "-i", str(mp4_path),
         "-vf", "crop=iw:iw:0:(ih-iw)/2,scale=256:256",
         "-c:v", "libtheora", "-q:v", "8", "-an", str(ogv_path)],
        check=True,
    )
    print(f"Saved {ogv_path}")


if __name__ == "__main__":
    main()
