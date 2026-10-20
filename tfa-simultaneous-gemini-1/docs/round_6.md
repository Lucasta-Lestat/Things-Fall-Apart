# Round 6: Toxic Shock, Chilled, unseen NPCs, threat awareness

This round implements your answers to round 5's decisions. Testing:
- Every existing harness is equal to or better than before.
- 4 new harnesses pass: status_conds_r6_test 142, unseen_targets_r6_test 125, threat_awareness_r6_test 103 and integration_r6_test 92.
- Everything ran headless. Nothing was played in a window.

## Toxic Shock: doubling until cured

Poisoned still turns into Toxic Shock at 4 stacks. Toxic Shock now has no timer. It deals 1 poison every 2 s, and the tick doubles every time: 1, 2, 4, 8, 16, then 32 at most. Armour doesn't reduce it. It ends only when it's cured or the bearer dies. Round 5's slow is gone.

| Tick | Time | Damage | Total |
|---|---|---|---|
| 1 | 0 s | 1 | 1 |
| 2 | 2 s | 2 | 3 |
| 3 | 4 s | 4 | 7 |
| 4 | 6 s | 8 | 15 |
| 5 | 8 s | 16 | 31 |
| 6+ | every 2 s | 32 | |

How long it takes to kill:
- A 30-HP character from full dies at 8 s, which leaves about 6 s to cure.
- A 50-HP character dies at 10 s, and a 100-HP NPC at 14 s.

**More poison while it's on** moves it one doubling forward. It never resets. The float reads "Toxic Shock worsens", or "(already on)" at its peak. Pokémon's exact rule, where a second Toxic does nothing, is `redose_steps: 0`.

**Feedback**
- **Hover:** "Toxic Shock: 8 poison every 2 s, doubling (cure: Heal or a Potion of Healing)".
- **At onset:** a party member gets a cure hint.
- **When the next tick would kill:** one warning, "Ada will die from Toxic Shock unless cured (next tick 16 poison, 15 HP left)."
- **Poisoned's own description** now warns that its 4th stack kills unless cured.

**Under the hood**
- **Doubling:** a general data option, `"escalate": {multiplier, max_value, redose_steps}`, so other conditions can use it.
- **Saves:** the tick it has reached is saved and survives a load.
- **Load-timing fix:** a loaded DoT used to tick the moment the game loaded. It now keeps its rhythm.

**Cures that exist**
- **Potion of Healing:** you can trade for one with Liana (2), Magda (2), Mostlemyre Drouge (1) and Federica (1), and there's one on the cemetery floor.
- **Heal:** only the Bandit Shaman, an enemy, knows it.
- **Antidote and purify traits:** both are wired up, but nothing in the game carries them.

**Toxic Shock icon.** The Gemini API refused all 27 requests with HTTP 402 ("prepayment credits are depleted"). Toxic Shock still uses Poisoned's icon. The prompts are in `tools/generate_condition_icons_gemini.py`. Once your credit is topped up:

```bash
python tools/generate_condition_icons_gemini.py --out <dir> toxic_shock
```

Then pick a candidate with `--pick toxic_shock=<file>`, and point the `toxic_shock` icon at `cond_toxic_shock.png` with `icon_fallback` set to `poisoned.png`.

## Chilled freezes at 4

It was 3 stacks, not 2. Since round 5, an 11–15 cold hit added 3 stacks at once and froze immediately. Chilled now caps at 4 and freezes at 4.

| Source | Hits to freeze before | Now |
|---|---|---|
| Frost Axe (4 cold), Winter's Grip (3) | 3 | 4 |
| Iciclet (15 cold at STR 50–56) | 1 | 2 (leaves x3) |
| Any 16+ cold hit | 1 | 1 |

Dexterity drops 15% per stack, compounding: 85%, then 72%, then 61% at x3. The Iciclet's item text no longer claims it always freezes.

## Unseen NPCs can't be clicked

If nobody in the party can see an NPC right now, your mouse can't find it. "Can't see" covers:
- behind a wall, out of range or outside every view cone;
- fog;
- Invisible with no cue;
- on the other view layer.

For such an NPC:
- **Mouse:** no dagger or talk cursor, no hover tooltip, and no left-click designation.
- **Right-click menu:** no Talk, Trade, Attack or Search Body.
- **Spells:** no spell pick, and no "can't target" message either.
- **Previews:** aiming previews don't snap to it. The real spell still hits it.

Anything you saw when you paused stays clickable for the whole pause.

## Plans pause when the target is lost

A planned attack or spell never aims at an unseen target's true position. It aims at where the party last saw it.
- **Lost for more than 0.5 s when its step comes up:** the plan pauses with "Paused: Target lost". The log says "Target lost: Bandit is out of sight. Aldric's plan is paused." If Invisible is the reason, it says "is invisible".
- **Lost for under 0.5 s:** Aldric swings at the last-seen spot, with no pause and no log. A target circling a pillar doesn't spam pause and resume.
- **Lost mid-swing or mid-cast:** the aim moves to the last-seen spot. A single-target spell lands there instead.
- **Seen again:** "Aldric can see Bandit again: plan resumes."
- **Target dies:** the plan is dropped.

## Combat music and Surrender wait for a known threat

Both appear only for a hostile within the old 800 px radius that the party knows about. Known means:
- the party sees it now;
- the party saw it within the last 10 s of game time;
- a blow or condition passed between it and a party member within that window;
- a party member heard it within 2 tiles in that window.

So an enemy stepping behind a wall mid-fight keeps the music going. A hidden or invisible enemy nearby starts nothing until it gives itself away. Your own Acid Rain or Freezing Rain landing on everyone doesn't count.

The Surrender panel only picks from known threats. If none is left, it says "No one to surrender to".

**Lines that named NPCs nobody could see now hide them:**
- "Burning is put out (cold: a hit from someone unseen)."
- Sickness spreading, vomiting and summoned animals.
- Disarms.
- The Confess, Hitch and Fatal Attraction lines.
- The Infatuated refusal line.
- The confusion line.
- A dialogue's "Combat!" line: "Someone unseen attacks you."

## Bleeding: answer to "any flaws?"

Yes, several. CON or max-HP loss stops the double dip mostly by removing Bleeding's effect.

1. **It does almost nothing in a fight.** Losing max HP only matters once max drops below current HP, and the cut already took more than that. A bandit cut for 15 is at 15/30; losing even 10 max HP leaves 15/20. Enemies almost never heal, so against them it does nothing.
2. **CON is a weak lever.** 5 CON is 1 max HP. CON is also Bleeding's own save stat, so lowering it makes bleeding harder to shake off. CON loss is already what Fatigued and Exhausted do.
3. **It can't kill.** Max HP can't go below 1, and lowering it never triggers the death check.
4. **It's invisible.** When it does cut into HP, there's no number or log line. The HP bar looks fuller as max shrinks.
5. **Healing undoes it.** Heal and the Potion of Healing cure Bleeding before they heal.
6. **Swords, spears and arrows would lose their only edge.** Maces and hammers deal about the same damage.

**Recommendation: keep Bleeding as damage over time, but 1 stack per slashing or piercing hit, however big.** That is how it worked before round 5, and it's one data value (`damage_per_stack` 0 on Bleeding).
- A single cut then adds about 2 damage on average instead of about 10.
- Four sword hits add about 10 instead of 30.
- Quick blades, arrows, wolves and rats become the bleeders.
- The Jaws That Bite, Alms of the Vein and severed limbs keep their bigger bleeds.

Optional extra: make a mixed hit like the Halberd's apply one wound instead of two.

If you also want lasting injuries, add a separate "Deep Wound" rather than replacing Bleeding:
- **Trigger:** a 20+ hit, then a failed CON save.
- **Effect:** −3 max HP per stack.
- **Cure:** rest or a bandage.

It would mainly affect the party, since enemies don't heal.

## Try it in game

1. **Toxic Shock:**
   - Throw a Poison Vial at an enemy and hover it: 1, 2, 4, 8… doubling.
   - Do the same on a party member to get the cure hint and the "will die" warning, then drink a Potion of Healing to end it.
2. **Chilled:** an Iciclet leaves Chilled x3 and the next cold freezes. The Frost Axe takes 4 hits.
3. **Unseen NPCs:** put a wall between the party and a bandit. Hovering there shows nothing, and right-clicking gives no menu.
4. **Plan pause:** plan an attack, then let the target walk behind a building before that step. Expect "Target lost" once, then "plan resumes" when it reappears.
5. **Threat awareness:**
   - Walk near a hidden enemy. There should be no music and no Surrender button.
   - Let it hit someone, and both appear.
   - Break line of sight mid-fight. Surrender should stay about 10 s.

## Open decisions

1. **Toxic Shock on the world map (needs a decision).** The world map runs at 7200× time, so an uncured Toxic Shock kills the protagonist a fraction of a second after they leave a local map. Before, the 10 s version just expired there. My recommendation: block leaving a local map while anyone has Toxic Shock, with a clear message. They'd die within seconds anyway, so this only makes the cause readable. Alternatives: pause it on the world map, or let them die on the road with a log line.
2. **Cures.** Without a Potion of Healing, Toxic Shock is a death sentence. Add an antidote item? The trait already cures it. Make Heal learnable? Or accept it?
3. **More poison under Toxic Shock:** one doubling forward (current), or nothing (exact Pokémon)?
4. **Friendly fire.** 8 s in your own Cloud Kill is now fatal unless cured. Intended?
5. **Bleeding:** go with 1 stack per hit, the recommendation above?
6. **Out-of-sight items** (chests, loose items) can still be clicked, and the cursor changes over them. Filter them like NPCs?
7. **Unseen deaths.** The player can still learn that an unseen enemy died in three ways:
   - "plan dropped: Bandit is dead";
   - a plan step on a dead target doesn't pause;
   - Surrender vanishes at once.

   Hide that? My suggestion: treat a dead unseen target like a living one ("Target lost") until someone sees the body.
8. **Range.** The 800 px radius also limits the music, so a known archer farther away doesn't start it. Count known attackers at any range?
9. **Memory window.** Is 10 s right for an enemy you stopped seeing? It's `THREAT_MEMORY_SECONDS` in `Game.gd`.
10. **Roof-walkers in ground view** count as known threats, but nothing on screen marks them. Add a marker?

Still open from round 3: canceled_by_trait names nothing carries, Federica, plan details, rations, the log ticker, and Q9 (indoor maps, Acid Rain assault reports).
