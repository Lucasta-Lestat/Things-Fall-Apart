# SFX Credits

This file lists where the sound effects added to `sfx/` on 2026-11-01 came
from. They fill the gaps that `docs/sfx_audit.md` found. There are 96 files:
20 from Kenney, 28 from OpenGameArt, 42 generated with ElevenLabs, and 6
edited from sounds already in `sfx/`. Sounds that were already in `sfx/` are
not covered here.

**Players must be able to see the CC BY credits.** Put them on a credits
screen, in the README or on the store page. Eight files are CC BY 3.0, and
shipping them without the [Attribution block](#attribution-block) breaks
their licence. Everything else is CC0, generated, or edited from the
project's own audio, so it needs no credit. It is still listed below for the
record.

Licences were checked on each asset's own page (kenney.nl for Kenney, the
OpenGameArt page for OGA). We assume the build is **commercial**, so we only
accepted CC0, public domain, CC BY 3.0 and CC BY 4.0. We turned down
anything NonCommercial, ShareAlike, NoDerivatives, GPL-only, Sampling+, or
under a custom "free" licence.

---

## Kenney (CC0 1.0)

These are all © Kenney (<https://kenney.nl>) under CC0 1.0 Universal, so no
attribution is required. The packs used are:

- [RPG Audio](https://kenney.nl/assets/rpg-audio)
- [Impact Sounds](https://kenney.nl/assets/impact-sounds)
- [Music Jingles](https://kenney.nl/assets/music-jingles)
- [Casino Audio](https://kenney.nl/assets/casino-audio)

The zips came from Kenney's own OpenGameArt uploads, or for Impact Sounds an
unchanged mirror of `kenney_impact-sounds.zip`, because kenney.nl refuses
scripted downloads. Each pack's bundled `License.txt` was checked, and it
says CC0.

| File | Pack | Source file(s) | Edit |
|---|---|---|---|
| `armor_rustle.mp3` | RPG Audio | `cloth1`, `clothBelt2`, `handleCoins2` | Layered. The coin clinks are high-passed at 1.5 kHz so they sound like a light mail jingle. |
| `body_fall.mp3` | Impact Sounds + RPG Audio | `impactSoft_heavy_003`, `impactPunch_heavy_001`, `impactSoft_heavy_000`; `cloth3`, `beltHandle1` | Layered thud with cloth and gear on top. |
| `check_fail.mp3` | Music Jingles | `jingles_PIZZA05` | None |
| `check_success.mp3` | Music Jingles | `jingles_PIZZA16` | None |
| `dialogue_close.mp3` | RPG Audio | `bookClose` | None |
| `dialogue_open.mp3` | RPG Audio | `bookOpen` | None |
| `dice_roll_1.mp3` | Casino Audio | `dice-shake-1` (0.55-0.95 s), `dice-throw-1` | Shake, then a 60 ms gap, then the throw. |
| `dice_roll_2.mp3` | Casino Audio | `dice-shake-2` (0.75-1.15 s), `dice-throw-2` | Same as `dice_roll_1` |
| `dice_roll_3.mp3` | Casino Audio | `dice-shake-3` (0.55-0.95 s), `dice-throw-3` | Same as `dice_roll_1` |
| `door_close_1.mp3` | RPG Audio | `doorClose_3` | None |
| `door_close_2.mp3` | RPG Audio | `doorClose_4` | None |
| `door_open_1.mp3` | RPG Audio | `doorOpen_1` | None |
| `door_open_2.mp3` | RPG Audio | `doorOpen_2` | None |
| `door_unlock.mp3` | RPG Audio | `metalClick` | None |
| `dry_fire_click.mp3` | RPG Audio | `metalLatch` | None |
| `item_drop_soft.mp3` | RPG Audio | `dropLeather` | Right channel polarity-inverted. The source's channels partly cancelled each other in mono. |
| `land_thud.mp3` | Impact Sounds + RPG Audio | `impactSoft_medium_001`, `footstep01` | Layered thud and scuff. |
| `paper_rustle_1.mp3` | RPG Audio | `bookFlip1` | First 0.40 s cut. It was a near-silent page lift. |
| `paper_rustle_2.mp3` | RPG Audio | `bookFlip2` | None |
| `paper_rustle_3.mp3` | RPG Audio | `bookFlip3` | None |

## OpenGameArt

Each licence was checked on the asset's own OpenGameArt page.
**CC BY 3.0** rows need a credit. They are repeated in the Attribution block.

| File | Asset page | Author | Licence | Source file | Edit |
|---|---|---|---|---|---|
| `amb_cave_loop.ogg` | [loopable-dungeon-ambience](https://opengameart.org/content/loopable-dungeon-ambience) | JaggedStone | CC0 | `dungeon_ambient_1_0.ogg` | Whole track, 94 s. The author made it loop seamlessly. |
| `amb_spring_loop.ogg` | [stream-sounds](https://opengameart.org/content/stream-sounds) | kurt | **CC BY 3.0** | `stream-waterfall/stream1.ogg` | 5.0-16.5 s cut to a 10 s loop with a 1.5 s crossfade. 30 Hz high-pass. |
| `crate_break.mp3` | [35-wooden-crackshitsdestructions](https://opengameart.org/content/35-wooden-crackshitsdestructions) | Independent.nu (uploaded by qubodup) | CC0 | `wood_impact/crack07` | First 0.9 s |
| `door_locked.mp3` | [door-lock-sounds](https://opengameart.org/content/door-lock-sounds) | Cough-E | CC0 | `LockedDoorHandleJiggle.wav` | First 0.8 s |
| `drink_2.mp3` | [202-more-sound-effects](https://opengameart.org/content/202-more-sound-effects) | OwlishMedia | CC0 | `Drink/Drink_02`, `_04`, `_03` | Three swallows joined |
| `eat_1.mp3` | [apple-bite](https://opengameart.org/content/apple-bite) | AntumDeluge, from sonicmariobrotha (freesound 333825, CC0) | CC0 | `apple_bite_0.ogg` | None |
| `eat_2.mp3` | [7-eating-crunches](https://opengameart.org/content/7-eating-crunches) | StarNinjas (recorded by Tito) | CC0 | `crunch.2.ogg` | 0.25-1.10 s, 60 Hz high-pass |
| `eat_3.mp3` | [7-eating-crunches](https://opengameart.org/content/7-eating-crunches) | StarNinjas (recorded by Tito) | CC0 | `crunch.5.ogg` | 0.12-0.79 s, 60 Hz high-pass |
| `fire_douse.mp3` | [steam-release-sounds](https://opengameart.org/content/steam-release-sounds) | bart (Bart Kelsey) | CC0 | `steam hisses - Marker #4.wav` | First 1.0 s |
| `glass_break.mp3` | [breaking-bottle](https://opengameart.org/content/breaking-bottle) | spookymodem | **CC BY 3.0** | `Bottle Break.wav` | 0.28-1.30 s |
| `match_strike.mp3` | [fantasy-sound-effects-tinysized-sfx](https://opengameart.org/content/fantasy-sound-effects-tinysized-sfx) | Vehicle (Jan Schupke) | CC0 | `sfx-cc0/match-light-01.wav` | Flare after the strike raised 18 dB |
| `pain_beast_1.mp3` | [dog-snarl-grunt-grumble](https://opengameart.org/content/dog-snarl-grunt-grumble) | qubodup (Iwan Gabovitch) | CC0 | `dog/dog-snarl.flac` | None |
| `pain_beast_2.mp3` | [rat-monster-screams](https://opengameart.org/content/rat-monster-screams) | qubodup (Iwan Gabovitch) | **CC BY 3.0** | `qubodupRat/qubodupRatPain.flac` | None |
| `pain_beast_3.mp3` | [bear-growls](https://opengameart.org/content/bear-growls) | AntumDeluge (U.S. Fish & Wildlife Service recording) | CC0 | `flac/bear_01.flac` | 0.03-0.78 s |
| `pain_female_1.mp3` | [female-hurt-grunts-groans](https://opengameart.org/content/female-hurt-grunts-groans) | Nocturnal_Vanguard (AuraVoice) | CC0 | `female_hurt_grunts_groans_1.ogg` | 0.32-1.20 s |
| `pain_female_2.mp3` | same | Nocturnal_Vanguard (AuraVoice) | CC0 | same | 2.08-2.78 s |
| `pain_female_3.mp3` | same | Nocturnal_Vanguard (AuraVoice) | CC0 | same | 3.70-4.20 s |
| `pain_female_4.mp3` | same | Nocturnal_Vanguard (AuraVoice) | CC0 | same | 7.32-8.17 s |
| `pain_male_1.mp3` | [11-male-human-paindeath-sounds](https://opengameart.org/content/11-male-human-paindeath-sounds) | Michel Baradari (uploaded by qubodup) | **CC BY 3.0** | `player/pain1.wav` | None |
| `pain_male_2.mp3` | same | Michel Baradari | **CC BY 3.0** | `player/pain4.wav` | None |
| `pain_male_3.mp3` | same | Michel Baradari | **CC BY 3.0** | `player/painh.wav` | None |
| `pain_male_4.mp3` | same | Michel Baradari | **CC BY 3.0** | `player/paino.wav` | None |
| `rat_squeak_1.mp3` | [squeaky-rat](https://opengameart.org/content/squeaky-rat) | qubodup, from Zabuhailo (freesound 143125) and moneykube (freesound 38747), both CC0 | CC0 | `qubodupSqueakyRatAttack` + `...Pain` | Two squeaks, the second pitched up 3 semitones. 150 Hz high-pass. |
| `rat_squeak_2.mp3` | same | same | CC0 | `...Pain` + `...Attack` | Three pitch-shifted squeaks. 150 Hz high-pass. |
| `rat_squeak_3.mp3` | same | same | CC0 | `qubodupSqueakyRatDeath` | 150 Hz high-pass |
| `sheathe.mp3` | [fantasy-weapons-and-apparel-sfx-library](https://opengameart.org/content/fantasy-weapons-and-apparel-sfx-library) | Vehicle (Jan Schupke) | CC0 | `sfx/seax-sheathe-04.wav` | Slide above 1.2 kHz raised 15 dB before the thunk |
| `structure_break_stone.mp3` | [falling-rock](https://opengameart.org/content/falling-rock) | spookymodem | **CC BY 3.0** | `Falling Rock.wav` | 1.85-4.70 s |
| `structure_break_wood.mp3` | [35-wooden-crackshitsdestructions](https://opengameart.org/content/35-wooden-crackshitsdestructions) | Independent.nu (uploaded by qubodup) | CC0 | `wood_impact/crack03` | 0.08-2.00 s |

`pain_beast_2` is offered on its page under CC BY 3.0, GPL 3.0 and GPL 2.0.
We use it under **CC BY 3.0** only.

## ElevenLabs-generated

These were generated for this project with the **ElevenLabs Sound Effects
API** (`/v1/sound-generation`, model `eleven_text_to_sound_v2`) on a **paid
plan, which grants commercial use**. There is no third-party author or
licence, and no attribution is required. The exact prompt, duration and
`prompt_influence` behind each file are the recipes in
`tools/generate_missing_sfx.py`. That script regenerates any of them with
`--only <name>`.

| File | Edit after generation |
|---|---|
| `ability_learned.mp3` | None |
| `alarm_bell.mp3` | None |
| `alert_search.mp3` | Two-note edit: the first 0.16 s, then the whole take 5 semitones higher |
| `alert_spotted.mp3` | None |
| `amb_cemetery_loop.ogg` | Loop take. 30 Hz high-pass applied as a loop. |
| `amb_countryside_loop.ogg` | Loop take. 30 Hz high-pass applied as a loop. |
| `amb_tavern_loop.ogg` | Loop take |
| `amb_town_loop.ogg` | Loop take |
| `beast_death_1.mp3` | None |
| `beast_death_2.mp3` | None |
| `bleed.mp3` | None |
| `bleed_drip.mp3` | None |
| `church_bell.mp3` | None |
| `crime_sting.mp3` | 35 Hz high-pass |
| `drink_1.mp3` | None |
| `electric_jolt.mp3` | First 0.36 s |
| `favor_down.mp3` | Two-note edit of a single pluck (D3 then C3). 2.2 kHz low-pass. |
| `fire_crackle_loop.ogg` | Loop take. The loudest pop is softened, with the softening applied as a loop. |
| `fire_ignite.mp3` | None |
| `fizzle.mp3` | None |
| `gasp.mp3` | None |
| `gore.mp3` | None |
| `hush.mp3` | None |
| `ink_splat.mp3` | None |
| `march_drum.mp3` | 20 Hz high-pass to remove a DC offset |
| `monster_death.mp3` | None |
| `oil_gush_loop.ogg` | Mix of two loop takes, with the second 2 dB lower |
| `party_join.mp3` | None |
| `party_leave.mp3` | None |
| `quest_advance.mp3` | 40 Hz high-pass |
| `quest_complete.mp3` | None |
| `quest_fail.mp3` | 35 Hz high-pass |
| `quest_start.mp3` | 40 Hz high-pass |
| `smoke_hiss.mp3` | None |
| `stamp.mp3` | None |
| `stealth_off.mp3` | None |
| `stealth_on.mp3` | None |
| `stress_affliction.mp3` | Mix of two takes. The heartbeat take is on top. The string take is mixed in at half speed (-8 dB), plus a copy a semitone higher (-14 dB). |
| `stress_virtue.mp3` | Crescendo from -14 dB to 0 dB over the first 0.85 s |
| `swarm_skitter_loop.ogg` | Loop take. The last 0.5 s are crossfaded into the start, giving a 5.5 s loop. |
| `undead_death.mp3` | Mix of two takes: the bone clatter from one, then a ghostly exhale from the other |
| `vow_broken.mp3` | 0.4 s fade-out. The take was cut off mid-sustain. |

## Derived from existing project sounds

These are edits of files that were already in `sfx/`, so each one has the
same licence as its source.

| File | Source | Edit |
|---|---|---|
| `swing_heavy.mp3` | `slash.mp3` | Core whoosh only. Pitched down 5 semitones and slowed to 0.8x. 4.5 kHz low-pass, +3 dB low shelf. The low thump after the whoosh is turned down. |
| `swing_thrust.mp3` | `slash.mp3` | Core whoosh only. Pitched up 2 semitones. 250 Hz high-pass. Thump turned down. |
| `swing_light.mp3` | `slash.mp3` | Core whoosh only. Pitched up 4 semitones. 300 Hz high-pass. Thump turned down. |
| `throw_whoosh.mp3` | `slash.mp3` | Pitched down 2 semitones, 0.9x tempo. Band-pass around 2.4 kHz. 30 ms fade-in. |
| `ui_pause.mp3` | `haste_wind.mp3` + `ui-click.mp3` | 0.32 s of the wind, reversed and pitched down 4.3 semitones. A low-pass filter opens as it swells. It ends on one click from `ui-click`. |
| `ui_unpause.mp3` | `ui_pause` | Exact reverse of `ui_pause` |

The commit that added `haste_wind.mp3` (6ab06afa) says it was generated with
ElevenLabs. Nothing in the repo records where `slash.mp3` (added in f47f6f41)
or `ui-click.mp3` (added in f0a96d77) came from. Earlier stages assumed they
were the project's own generations. **Confirm their origin before shipping**,
because these six files (`swing_heavy`, `swing_thrust`, `swing_light`,
`throw_whoosh`, `ui_pause` and `ui_unpause`) have the same licence as those
two.

---

## Attribution block

Copy this into the credits screen exactly as written.

```
SOUND EFFECTS

"Stream Sounds" by kurt
https://opengameart.org/content/stream-sounds
Licensed under Creative Commons Attribution 3.0 (CC BY 3.0)
https://creativecommons.org/licenses/by/3.0/
Edited (cut to a loop, filtered, re-levelled) for this game.

"Breaking Bottle" and "Falling Rock" by spookymodem
https://opengameart.org/content/breaking-bottle
https://opengameart.org/content/falling-rock
Licensed under Creative Commons Attribution 3.0 (CC BY 3.0)
https://creativecommons.org/licenses/by/3.0/
Edited (trimmed, re-levelled) for this game.

"Rat Monster Screams" by qubodup (Iwan Gabovitch)
https://opengameart.org/content/rat-monster-screams
Licensed under Creative Commons Attribution 3.0 (CC BY 3.0)
https://creativecommons.org/licenses/by/3.0/
Edited (trimmed, re-levelled) for this game.

"11 Male Human Pain/Death Sounds" by Michel Baradari
https://opengameart.org/content/11-male-human-paindeath-sounds
Licensed under Creative Commons Attribution 3.0 (CC BY 3.0)
https://creativecommons.org/licenses/by/3.0/
Edited (trimmed, re-levelled) for this game.
```

### Also used, no attribution required

The following are CC0 or public domain. You may credit them as a courtesy:

- Kenney (kenney.nl): RPG Audio, Impact Sounds, Music Jingles, Casino Audio
- From OpenGameArt:
  - JaggedStone
  - Independent.nu
  - Cough-E
  - OwlishMedia
  - AntumDeluge (with sonicmariobrotha, and the U.S. Fish & Wildlife Service)
  - StarNinjas / Tito
  - Bart Kelsey
  - Vehicle (Jan Schupke)
  - qubodup (with Zabuhailo and moneykube)
  - Nocturnal_Vanguard (AuraVoice)

These were also used and need no credit:

- Sounds generated with the ElevenLabs Sound Effects API
- Edits of the project's own existing sounds

---

## Mastering applied to every file above

At install time every file was processed as follows:

- **Trimming.** Leading silence is cut to 5 ms or less, with a 2-5 ms
  fade-in. Trailing silence below -60 dB (relative to the peak) is cut, then
  the file gets a 15-25 ms fade-out.
- **DC offset.** Files with a DC offset get a 20 Hz high-pass.
- **Loudness.** Each file is normalised to its category's level, measured
  from the existing `sfx/` files. True peak stays at or below -1 dBTP.
  Files of 0.5 s or longer are matched on integrated loudness (BS.1770).
  Shorter files are matched on the RMS of their loudest 100 ms, which
  tracks LUFS within about 1 dB on the reference set. Mono files are
  measured as dual-mono, because Godot plays them on both speakers.
- **Limiting.** When the target needs more gain than the peak allows, a
  lookahead true-peak limiter takes off up to 3 dB. Anything left over
  stays below the target. This affects peaky foley: `match_strike` -12 dB,
  `door_unlock` and `gore` -8, `drink_1` -3, `paper_rustle`/`dice_roll`
  -2 to -6, `undead_death` -5. About a dozen others fall 1-4 dB short.
  Raise these with `volume_db` at the call site if needed.
- **Loops.** Loops are not trimmed or faded. DC is removed and they are
  levelled on integrated loudness, applied as a loop. Every loop was checked
  for a seamless join. The end-to-start sample step is within the normal
  step range of the file, and the level just before and after the seam
  differs by 4.3 dB at most. All loops are Ogg Vorbis (`-q:a 5`), because
  MP3 encoder padding would leave a gap at the loop point. The decoded
  length matches the source length exactly. Everything else is MP3
  (`libmp3lame -q:a 2`) at 44.1 kHz.

| Category | Target | Reference sounds in `sfx/` |
|---|---|---|
| UI | -20 | `ui-click`, `ui-navigation`, `trade_*` ×4, `chest_*` ×4 (median -20.05) |
| UI, soft (`ui_pause`, `ui_unpause`) | -23 | UI -3 dB. These play dozens of times per fight. |
| Stingers | -22.5 LUFS | `heal_chime` -24.4, `charm_chime` -22.5, `holy_cast` -11.7 |
| Combat | -16 LUFS | `slash`, `draw-steel`, `clash`, `sword-on-flesh`, `armor-impact` (median -15.9) |
| Swings (`swing_*`, `throw_whoosh`) | -21.1 dB (loudest 100 ms RMS) | Matched to `slash.mp3`, which they stand in for |
| DoT tick (`bleed_drip`) | -22 dB (loudest 100 ms RMS) | About 3 dB under `poison_tick` (-19.3) |
| Vocal | -16 LUFS | All five vocal clips: `man-death-scream` -19.7, `witness_huh` -16.4, `woman-death-scream` -16.1, `witness_scream` -5.9, `rage_roar` -5.4 |
| Vocal, small (`rat_squeak`) | -19 | Vocal -3 dB |
| World | -16 LUFS | `chest_open` -13.2, `coin_pickup` -20.0 (100 ms RMS). `explosion` -10.7 is the ceiling. |
| World, big (`structure_break_*`, `alarm_bell`) | -13 LUFS | World +3 dB, still under `explosion` |
| World, distant (`church_bell`) | -20 LUFS | World -4 dB |
| Loops (`fire_crackle`, `swarm_skitter`, `oil_gush`) | -25.6 LUFS | Median of `weather_*_loop` |
| Ambience beds (`amb_*`) | -31.6 LUFS | Weather-loop median -6 dB. SfxManager also plays ambience at `AMBIENCE_DB` -4. |
