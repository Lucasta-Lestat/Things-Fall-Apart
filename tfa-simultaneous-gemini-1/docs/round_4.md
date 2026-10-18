# Round 4: DoT rescale, stealth and witness fixes, New Year bug

This round implements your answers to round 3's decisions. Testing:
- Every existing harness is equal to or better than before.
- 4 new harnesses pass: dot_r4_test 165, stealth_ai_r4_test 115, downtime_day_r4_test 48 and integration_r4_test 37.
- Everything ran headless. The one exception is the Shrouded tint, which was captured in a windowed render.

## DoT: small stacks, more stacks from bigger hits, refresh to the last application

**Stacks and tiers are the same thing.** It is one counter, capped by `max_tier`. Player-facing text now says "stacks" everywhere: the log, condition descriptions and Force March. Code names are unchanged.

**New numbers.** "Per stack" is what one stack deals over its whole duration. "Max" is damage per second at max stacks.

| Condition | Before | After |
|---|---|---|
| Burning | 72 per stack, max 4 (16/s), +1 per fire hit | 1 fire/s for 6 s = 6 per stack, max 3 (3/s), 1 stack per 6 fire dealt |
| Poisoned | 50 per stack, max 10 | 1 per 2 s for 10 s = 5 per stack, max 4 (2/s), 1 stack per 5 poison |
| Bleeding | 16 per stack, 1 per cut | 1 true per 2 s for 8 s = 4 per stack, max 5, 1 stack per 20 slashing/piercing (CON saves unchanged) |
| Corroding | 18 per stack, max 5 | 1/s for 4 s = 4 per stack, max 3 |
| Shocked | 6 per stack | 2 per stack, max 3/s |
| Stuck in Fire | 10 per catch | 6 per catch |
| Chilled | 1 stack per cold hit | 1 stack per 12 cold dealt; a 25+ cold hit freezes at once |

- A rider adds `ceil(damage dealt of that type ÷ damage_per_stack)` stacks: at least 1, at most the cap. `damage_per_stack` is a new field on each condition in ConditionDatabase, so you can tune it there.
- Spells, surfaces, fogs and weather keep their authored stack counts.

Examples of the extra DoT damage on top of the hit:

| Source | Before | After |
|---|---|---|
| Match Striker | 72 | 6 |
| Flaming Sword | 72 | 6 per hit, up to 3/s while you keep hitting |
| Fireball | 144 | 12 |
| Poison Vial | 50 | 20 |
| Cloud Kill (whole duration) | 245 | 38 |
| 3 s on burning ground | 198 | 21 |

A 30-HP character held at max stacks dies in about 9–14 s.

**Refresh.**
- Every application of a stacking condition with a timer extends it to `now + duration`, including one that lands at the cap. Burning now goes out about 6 s after your *last* hit.
- This also covers Exhausted (24 h from the last Force March) and Grappled. A claw creature that keeps grabbing now holds until the STR saves break it.
- Ticks keep their own rhythm, so a refresh never adds an extra tick.
- Old saves with stacks above the new caps are held to the cap on load.

**Hover text** shows what a DoT does now, e.g. "Burning x3: 3 fire every 1 s (6s left)". It appears in the party panel, overhead icons, world hover and the downtime portraits. Rider stacks still add nothing to the log.

## Invisible, Shrouded and witnesses

- **Enemies lose you when Invisible returns.** Their "!" turns to "?" and the log says "Town Guard loses sight of Djargo (invisible)." They search where you were last seen, and can't target you again until your next attack or cast reveals you. True Sight still sees you.
- **Invisible sneaking no longer wakes resting NPCs.** The wake check is now the same test as the stealth eye. Noise still wakes them.
- **Crime witnesses respect concealment:**
  - **Invisible:** witnesses never see you. Thefts, looting and casts done while Invisible go unseen ("Unseen (Invisible)" / "No one saw it: Djargo was Invisible.").
  - **Shrouded:** witnesses see you only within half their sight range (about 11 tiles), so the same applies beyond that.
  - **Crimes with a victim:** bystanders see the deed but not who did it. That raises the existing anonymous alarm, with no standing loss.
  - The 3 s after you attack or cast count as visible.
- **Shrouded feedback:**
  - Shrouded characters are drawn with a dark violet-grey tint. It changes colour, not opacity, so it stays distinct from Invisible's see-through look.
  - Attacking or casting lifts the tint. "Revealed" floats over the character, and the log says "Djargo is revealed for 3 s (attacking)."
  - The pip and hover text show "(revealed 2s)".
  - When the window ends: "Shrouded returns".
  - With the Shadow Cloak also on, you get only the cloak's pair of notices.
  - NPCs get the tint and floats, but no log lines.
  - To tune the colour, change `ProceduralCharacter.CONCEALED_TINT`.

## New Year bug

- Downtime cooldowns now count days actually lived, so 7 days is exactly 7 days across New Year and leap-year Yearturn.
- Old save entries are converted to the new count when loaded.
- The same Yearturn fault was in two other places, and both are fixed:
  - Quest day counters: a 7-day deadline started in late Mistumnal of a leap year ran 19 days.
  - The scheduled-dialogue clock, which isn't used by any data yet. Two latent script errors in it are also fixed.

## Open decisions

1. **Armour against DoT ticks.** Armour subtracts a flat amount per tick, with a minimum of 1. Leather's fire 2 therefore turns any Burning tick into 1, so maxed Burning on a leather-armoured target is 1/s, not 3. Should DoT ticks ignore armour? The hover numbers are before armour.
2. **Acid Rain.** Standing outside for its full 60 s still deals 61, which kills a 30-HP character. Should it be weaker?
3. **Burning's ×1.2 duration** from the default trait table: keep it? Burning is 5 s in the data and 6 s in play.
4. **Poisoned's toxic_shock transform.** It sits at tier 10, which can no longer be reached with a cap of 4, and toxic_shock was never defined. Set it to 4, or delete it?
5. **Invisible NPCs** are still drawn fully opaque to you; only their icon shows it. Should they be see-through, like Invisible party members?

Round 3's other open decisions in `docs/round_3.md` are still open, as is question 9.
